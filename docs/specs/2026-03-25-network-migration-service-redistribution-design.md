# Network Migration & Service Redistribution Design

**Date:** 2026-03-25
**Status:** Approved
**Scope:** Full IP migration from 10.0.0.x to 192.168.0.x, service redistribution across 4 nodes

## Background

The homelab switched from a direct ethernet interconnect (10.0.0.0/24) to a TP-Link LAN (192.168.0.0/24). All cross-node references using 10.0.0.x are broken. Additionally, two new nodes (lw-c1 compute, lw35 NAS) were added and services need redistribution.

## Target Topology

| Node | Hostname | IP | Role | Services |
|------|----------|----|------|----------|
| Node 1 | lw-main | 192.168.0.105 | Core infra + monitoring | Caddy, Authelia, WireGuard, Pi-hole, Homepage, Grafana stack, LibreNMS, Vault, Nexterm, Lightpanda, **Netbox** |
| Node 2 | lw-s1 | 192.168.0.108 | Automation | n8n, Dify, GitHub runner |
| Compute | lw-c1 | 192.168.0.107 | Compute | Proxmox → K8s, OpenClaw, Ollama |
| NAS | lw35 | 10.0.1.2 | Storage + data | **Paperless**, **Seafile**, shared-postgres, shared-mariadb, shared-redis |

## Networks

| Network | CIDR | Purpose |
|---------|------|---------|
| LAN | 192.168.0.0/24 | Home network via TP-Link, gateway 192.168.0.1 |
| NAS link | 10.0.1.0/24 | Direct USB ethernet: node1 (10.0.1.1) ↔ NAS (10.0.1.2) |
| VPN | 10.8.0.0/24 | WireGuard overlay, gateway 10.8.0.1 |
| Docker homelab-net | 172.20.0.0/24 | Node1 internal Docker network |

## Ansible Variable Strategy

Replace all hardcoded IPs with variables. Each playbook's `group_vars/all.yml` or a shared common vars file defines:

```yaml
node1_ip: "192.168.0.105"    # lw-main
node2_ip: "192.168.0.108"    # lw-s1
nas_ip: "10.0.1.2"           # lw35
compute_ip: "192.168.0.107"  # lw-c1
```

This way future IP changes only require updating one place.

---

## Phase 1: NAS Link Automation

**New playbook:** `infrastructure/nas-link-setup/`

**Runs on:** node1 + NAS

**What it automates:**

On node1:
- Netplan config for USB ethernet adapter `enx00e04c360158` → `10.0.1.1/24`
- `sysctl net.ipv4.ip_forward=1` (persistent)
- UFW MASQUERADE rules in `/etc/ufw/before.rules` for NAT (10.0.1.0/24 → wlx/eno1)
- UFW allow rules for NAS access (SSH, database ports)

On NAS (lw35):
- Netplan config for `eno1` → `10.0.1.2/24`, gateway `10.0.1.1`, DNS `1.1.1.1`
- Install Docker and prerequisites
- UFW setup with rules: allow PostgreSQL (5432), MariaDB (3306), Redis (6379), SSH (22) from `192.168.0.0/24` and `10.0.1.1` only

On node2:
- Static route: `10.0.1.0/24 via 192.168.0.105` so node2 services can reach NAS databases

**Inventory:**

```ini
[nas_link]
192.168.0.105 ansible_user=kamil-rybacki  # node1
10.0.1.2 ansible_user=kamil               # NAS (reachable after node1 config)

[nas_route]
192.168.0.108 ansible_user=kamil           # node2 (needs route to NAS)
```

---

## Phase 2: Databases to NAS

**Playbooks:** Existing `infrastructure/shared-postgres-setup/`, `shared-mariadb-setup/`, `shared-redis-setup/`

**Changes to group_vars:**

```yaml
# shared-postgres-setup/group_vars/all.yml
shared_postgres_bind_address: "10.0.1.2"  # was 10.0.0.2 — bind to NAS link IP only

# shared-mariadb-setup/group_vars/all.yml
shared_mariadb_bind_address: "10.0.1.2"   # was 10.0.0.2

# shared-redis-setup/group_vars/all.yml
shared_redis_bind_address: "10.0.1.2"     # was 10.0.0.2

# common/shared-database/defaults.yml
shared_db_host: "10.0.1.2"               # was 10.0.0.2
```

**Also update `vars_prompt` defaults** in these setup playbooks:

| File | Change |
|------|--------|
| `infrastructure/shared-postgres-setup/setup.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/shared-mariadb-setup/setup.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/shared-redis-setup/setup.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/service-startup-setup/setup.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/migrate-to-shared/migrate.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/migrate-to-shared/cleanup.yml` | `default: "10.0.0.2"` → `default: "10.0.1.2"` |
| `infrastructure/netbox-agent-setup/setup.yml` | Update example IPs in prompts |

**Migration steps:**
1. Verify Docker is running on NAS (prerequisite from Phase 1)
2. Deploy fresh database containers on NAS
3. Dump data from node2: `pg_dumpall`, `mysqldump --all-databases`, Redis `BGSAVE`
4. Restore on NAS
5. **Verify data integrity:** row count comparisons for critical tables (netbox, paperless, n8n)
6. Verify connectivity from node1 and node2
7. Stop old database containers on node2

**Bind address security:** Databases bind to `10.0.1.2` (the NAS link IP), NOT `0.0.0.0`. This avoids the Docker + UFW bypass issue where Docker's iptables rules circumvent UFW on published ports. All consumers reach the NAS via `10.0.1.2` — node1 directly via USB ethernet, node2 via static route through node1.

---

## Phase 3: Paperless to NAS + Seafile on NAS

### Paperless Migration

**Playbook:** Existing `files/paperless-setup/`

**Steps:**
1. Deploy Paperless container on NAS
2. Copy media/data directory from node2 → NAS
3. Point at shared-postgres on localhost (`10.0.1.2`) and **shared-redis on localhost** (`10.0.1.2`, DB 3)
4. Verify document access
5. Update Caddy: `paperless.{{ domain }}` → `{{ nas_ip }}:8000`
6. Update Paperless MCP: `paperless_api_url: "http://{{ nas_ip }}:8000"`
7. Remove Paperless from node2

### Seafile Deployment

**Playbook:** Existing `files/seafile-setup/` — **requires refactoring**

The existing playbook bundles its own standalone MariaDB (`seafile-db`) and Caddy (`seafile-caddy`) containers. Refactoring needed:
1. Remove bundled `seafile-db` container — wire Seafile to shared-mariadb on the same host
2. Remove bundled `seafile-caddy` — route through main Caddy on node1
3. Assign port **8082** for Seafile (avoids conflict with LibreNMS on 8080)

**Steps after refactoring:**
1. Deploy Seafile on NAS using shared-mariadb (localhost `10.0.1.2`)
2. Add Caddy entry: `seafile.{{ domain }}` → `{{ nas_ip }}:8082`
3. Add Homepage entry
4. Configure Authelia OIDC if supported

---

## Phase 4: Netbox to Node1

**Playbook:** Existing `monitoring/netbox-setup/`

**Steps:**
1. Deploy Netbox on node1
2. Database stays on NAS (shared-postgres) — Netbox connects via `{{ nas_ip }}:5432`
3. Redis on NAS — connects via `{{ nas_ip }}:6379`
4. Update Caddy: `netbox.{{ domain }}` → `localhost:8081` (same host, simpler)
5. Join Netbox containers to `homelab-net` for Authelia header auth
6. Remove Netbox from node2

---

## Phase 5: IP Migration — All Config Updates

### Caddy Routing

**Note:** Not all routes live in `Caddyfile.j2`. Some services (n8n, Grafana, LibreNMS) dynamically append their Caddy routes via their own `setup.yml` playbooks directly into `/opt/homelab/caddy/Caddyfile`. The table below indicates which mechanism each route uses.

| Subdomain | Old Target | New Target | Route Mechanism |
|-----------|-----------|------------|-----------------|
| `n8n.{{ domain }}` | `10.0.0.2:5678` | `{{ node2_ip }}:5678` | **Dynamic** (n8n-setup/setup.yml) |
| `netbox.{{ domain }}` | `10.0.0.2:8081` | `localhost:8081` | **Dynamic** (netbox-setup/setup.yml) |
| `paperless.{{ domain }}` | `10.0.0.2:8000` | `{{ nas_ip }}:8000` | **Dynamic** (paperless-setup/setup.yml) |
| `seafile.{{ domain }}` | (new) | `{{ nas_ip }}:8082` | **Dynamic** (seafile-setup/setup.yml) |
| `dify.{{ domain }}` | (new) | `{{ node2_ip }}:80` | **Dynamic** (dify-setup/setup.yml) |
| `grafana.{{ domain }}` | localhost:3000 | unchanged | **Dynamic** (grafana-stack-setup/setup.yml) |
| Core services (auth, home, cockpit, wg, pihole, openclaw) | various | unchanged | **Template** (Caddyfile.j2) |

### Monitoring (Alloy)

| Config | Old | New |
|--------|-----|-----|
| Alloy agent (node2) → Mimir | `10.0.0.1:9009` (vars_prompt default) | `{{ node1_ip }}:9009` |
| Alloy agent (node2) → Loki | `10.0.0.1:3100` (vars_prompt default) | `{{ node1_ip }}:3100` |
| New: Alloy agent on NAS | — | Reports to `{{ node1_ip }}:9009` and `{{ node1_ip }}:3100` |
| Netbox scrape | `10.0.0.2:8081` | `localhost:8081` |
| Paperless probe | `10.0.0.2:8000` | `{{ nas_ip }}:8000` |
| Grafana stack `group_vars/all.yml` probe URLs | `probe_*_url: 10.0.0.2:*` | Update to new targets |

**Note:** Alloy agent setup uses `vars_prompt` for Mimir/Loki host — update the prompt defaults, not hardcoded template values.

### Other References

| File | Old | New |
|------|-----|-----|
| `nexterm-setup/group_vars/all.yml` | `10.0.0.1`, `10.0.0.2` | `{{ node1_ip }}`, `{{ node2_ip }}` |
| `paperless-mcp-setup/group_vars/all.yml` | `http://10.0.0.2:8000` | `http://{{ nas_ip }}:8000` |
| `github-runner-setup/inventory/hosts.ini` | `10.0.0.2` | `{{ node2_ip }}` |
| `alloy-agent-setup` vars_prompt defaults | `10.0.0.1` example | `{{ node1_ip }}` |
| `dev-tools/grepai-setup/` Ollama reference | localhost Ollama | `{{ compute_ip }}` (after Phase 7) |
| `common/shared-database/detect.yml` | May reference `10.0.0.x` | Update to `{{ nas_ip }}` |

### Homepage Dashboard

No IP changes needed — Homepage uses `https://<subdomain>.{{ domain }}` URLs which route through Caddy. Only updates:
- Add Seafile service entry
- Add Dify service entry
- Update any node labels if shown

### Authelia Access Control

**Tighten network policies.** The `10.0.0.0/8` rule was intended for two nodes on `10.0.0.0/24` which no longer exists. Narrow it:

| Old | New | Reason |
|-----|-----|--------|
| `10.0.0.0/8` (single-factor) | `10.0.1.0/24` (single-factor) | Only NAS link uses 10.x now |
| `10.8.0.0/24` | unchanged | WireGuard VPN |
| `192.168.0.0/16` | unchanged | LAN |
| `172.20.0.0/24` | unchanged | Docker bypass |

Also update Caddy UFW rule in `security/secure-homelab-access/roles/caddy/tasks/main.yml`: change metrics allow from `10.0.0.0/8` → `10.0.1.0/24`.

### Post-Migration: Restart All Services

After all IP changes, restart all service containers on every node to clear DNS caches and stale connections. Any service that cached `10.0.0.x` addresses will pick up the new targets.

---

## Phase 6: Node2 Cleanup

After all migrations verified:

1. Stop and remove: shared-postgres, shared-mariadb, shared-redis, Netbox, Paperless containers
2. Remove Docker volumes (after confirming data migrated)
3. Remove `databases-net`, `netbox-net`, `paperless-net` Docker networks
4. Remove service-startup-setup orchestration (databases no longer on node2)
5. Node2 final state: n8n, Dify, GitHub runner, docker-exporter, Alloy agent

---

## Phase 7: lw-c1 Proxmox Setup (Separate Project)

**Not Ansible-driven initially.** Proxmox is a bare-metal hypervisor.

**Steps:**
1. Install Proxmox VE on lw-c1 (USB boot, manual install)
2. Configure networking: bridge to 192.168.0.0/24
3. Use existing `k8s/proxmox-k8s-setup/` playbook to provision K8s clusters
4. Deploy OpenClaw as a container/VM inside Proxmox
5. Deploy Ollama as a container/VM inside Proxmox
6. Remove OpenClaw and Ollama from node1

---

## Execution Order & Dependencies

```
Phase 1: NAS Link Automation
    ↓
Phase 2: Databases → NAS
    ↓
Phase 3: Paperless → NAS + Seafile on NAS  (parallel)
Phase 4: Netbox → Node1                     (parallel)
    ↓
Phase 5: IP Migration — all config updates
    ↓
Phase 6: Node2 cleanup
    ↓
Phase 7: Proxmox on lw-c1 (independent, can start anytime after Phase 1)
```

Phases 3 and 4 can run in parallel since they have no dependency on each other — only on Phase 2 (databases on NAS).

Phase 7 is independent — Proxmox install can begin as soon as the network is set up, but OpenClaw/Ollama migration waits until Proxmox + K8s are ready.

---

## Known Risks

**NAS as single point of failure:** All databases move to a single NAS connected via USB ethernet. If the NAS or the link goes down, every database-dependent service fails. Mitigation: scheduled `pg_dumpall` and `mysqldump` backups to node1 via cron (daily at minimum).

**USB ethernet bandwidth:** The USB adapter runs at 10Mb/s. Fine for database queries but could bottleneck bulk data transfers (Paperless document uploads, Seafile syncs). Monitor and consider upgrading to a PCIe NIC or gigabit USB 3.0 adapter if needed.

**Netbox database latency:** Netbox on node1 connects to PostgreSQL on the NAS via the USB link. The 10Mb/s link adds latency compared to localhost. Acceptable for a homelab but worth monitoring.

**Cloudflared config:** `security/secure-homelab-access/roles/cloudflared/templates/config.yml.j2` routes `*.{{ domain }}` to `localhost:80` — this is correct and needs no IP changes (already updated to http2 protocol in this session).

---

## Rollback Strategy

Each phase is independently reversible:
- Database dumps are kept on node2 until Phase 6 cleanup
- Old containers stay stopped (not removed) until verification
- Caddy config changes are atomic — one `netplan apply` / `docker restart caddy`
- If a phase fails, previous services on the old node are still available to restart

---

## Files Modified

### Core networking & variables
| File | Changes |
|------|---------|
| `security/secure-homelab-access/group_vars/all.yml` | Add node IP variables |
| `common/shared-database/defaults.yml` | `shared_db_host` → `10.0.1.2` |
| `common/shared-database/detect.yml` | Update any `10.0.0.x` references |
| **New:** `infrastructure/nas-link-setup/` | Full NAS networking automation |

### Database infrastructure
| File | Changes |
|------|---------|
| `infrastructure/shared-postgres-setup/group_vars/all.yml` | Bind to `10.0.1.2` |
| `infrastructure/shared-postgres-setup/setup.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/shared-mariadb-setup/group_vars/all.yml` | Bind to `10.0.1.2` |
| `infrastructure/shared-mariadb-setup/setup.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/shared-redis-setup/group_vars/all.yml` | Bind to `10.0.1.2` |
| `infrastructure/shared-redis-setup/setup.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/service-startup-setup/setup.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/migrate-to-shared/migrate.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/migrate-to-shared/cleanup.yml` | vars_prompt default → `10.0.1.2` |
| `infrastructure/netbox-agent-setup/setup.yml` | Update example IPs in prompts |

### Security & access control
| File | Changes |
|------|---------|
| `security/secure-homelab-access/roles/caddy/templates/Caddyfile.j2` | Update core proxy targets |
| `security/secure-homelab-access/roles/caddy/tasks/main.yml` | UFW metrics: `10.0.0.0/8` → `10.0.1.0/24` |
| `security/secure-homelab-access/roles/authelia/templates/configuration.yml.j2` | Narrow `10.0.0.0/8` → `10.0.1.0/24` |

### Service playbooks (dynamic Caddy routes)
| File | Changes |
|------|---------|
| `automation/n8n-setup/setup.yml` | Caddy route: `{{ node2_ip }}:5678` |
| `monitoring/netbox-setup/setup.yml` | Caddy route: `localhost:8081` |
| `files/paperless-setup/setup.yml` | Caddy route: `{{ nas_ip }}:8000` |
| `files/seafile-setup/` | Refactor: remove bundled DB/Caddy, use shared-mariadb, port 8082 |
| `ai/dify-setup/setup.yml` | Caddy route: `{{ node2_ip }}:80` |

### Monitoring
| File | Changes |
|------|---------|
| `monitoring/grafana-stack-setup/group_vars/all.yml` | Update probe URLs |
| `monitoring/grafana-stack-setup/roles/*/templates/alloy.river.j2` | Update scrape targets |
| `monitoring/alloy-agent-setup/` vars_prompt defaults | `{{ node1_ip }}` for Mimir/Loki |

### Dev tools & other
| File | Changes |
|------|---------|
| `dev-tools/nexterm-setup/group_vars/all.yml` | Update host IPs |
| `dev-tools/paperless-mcp-setup/group_vars/all.yml` | Update API URL |
| `dev-tools/github-runner-setup/inventory/hosts.ini` | Update node2 IP |
| `dev-tools/grepai-setup/` | Update Ollama reference (after Phase 7) |
| `security/secure-homelab-access/roles/homepage/templates/services.yaml.j2` | Add Seafile, Dify entries |
