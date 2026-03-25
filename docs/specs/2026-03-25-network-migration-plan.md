# Network Migration & Service Redistribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all homelab cross-node references from 10.0.0.x to 192.168.0.x/10.0.1.x, automate NAS networking, and redistribute services across 4 nodes.

**Architecture:** Sequential 7-phase migration. Each phase produces a working state. Databases move to NAS (10.0.1.2) via direct USB ethernet link from node1. Services update to use new IPs via Ansible variables. Caddy routes updated per-service (some in template, some dynamically appended by playbooks).

**Tech Stack:** Ansible, Docker, netplan/systemd-networkd, UFW, Caddy, PostgreSQL, MariaDB, Redis/Valkey

**Spec:** `docs/specs/2026-03-25-network-migration-service-redistribution-design.md`

**SSH access (verified this session):**
- node1 (lw-main): `kamil-rybacki@192.168.0.105`
- node2 (lw-s1): `kamil@192.168.0.108`
- lw-c1: `kamil@192.168.0.107`
- NAS (lw35): `kamil@10.0.1.2` (via node1 USB ethernet)

---

## Phase 1: NAS Link Automation

### Task 1.1: Create NAS link playbook structure

**Files:**
- Create: `infrastructure/nas-link-setup/setup.yml`
- Create: `infrastructure/nas-link-setup/inventory/hosts.ini`
- Create: `infrastructure/nas-link-setup/group_vars/all.yml`
- Create: `infrastructure/nas-link-setup/roles/nas-link-node1/tasks/main.yml`
- Create: `infrastructure/nas-link-setup/roles/nas-link-node1/templates/10-nas-link.yaml.j2`
- Create: `infrastructure/nas-link-setup/roles/nas-link-node1/handlers/main.yml`
- Create: `infrastructure/nas-link-setup/roles/nas-link-nas/tasks/main.yml`
- Create: `infrastructure/nas-link-setup/roles/nas-link-nas/templates/00-eno1.yaml.j2`
- Create: `infrastructure/nas-link-setup/roles/nas-link-nas/handlers/main.yml`
- Create: `infrastructure/nas-link-setup/roles/nas-link-route/tasks/main.yml`

- [ ] **Step 1: Create group_vars**

```yaml
# infrastructure/nas-link-setup/group_vars/all.yml
---
# NAS direct link
nas_link_node1_interface: "enx00e04c360158"
nas_link_node1_mac: "00:e0:4c:36:01:58"
nas_link_node1_ip: "10.0.1.1"
nas_link_nas_interface: "eno1"
nas_link_nas_mac: "18:03:73:1f:85:ae"
nas_link_nas_ip: "10.0.1.2"
nas_link_subnet: "10.0.1.0/24"
nas_link_cidr: "24"

# Node IPs (used across playbooks)
node1_ip: "192.168.0.105"
node2_ip: "192.168.0.108"
```

- [ ] **Step 2: Create node1 role — netplan template**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-node1/templates/10-nas-link.yaml.j2
network:
  version: 2
  renderer: networkd
  ethernets:
    {{ nas_link_node1_interface }}:
      match:
        macaddress: {{ nas_link_node1_mac }}
      addresses:
        - {{ nas_link_node1_ip }}/{{ nas_link_cidr }}
```

- [ ] **Step 3: Create node1 role — tasks**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-node1/tasks/main.yml
---
- name: Deploy NAS link netplan config
  template:
    src: 10-nas-link.yaml.j2
    dest: /etc/netplan/10-nas-link.yaml
    owner: root
    group: root
    mode: "0600"
  notify: apply netplan

- name: Enable IP forwarding (persistent)
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: true
    state: present
    reload: true

- name: Add NAT MASQUERADE rules to UFW before.rules
  blockinfile:
    path: /etc/ufw/before.rules
    insertbefore: "^\\*filter"
    marker: "# {mark} ANSIBLE MANAGED - NAS NAT"
    block: |
      *nat
      :POSTROUTING ACCEPT [0:0]
      -A POSTROUTING -s {{ nas_link_subnet }} -o wlx30169dd56e93 -j MASQUERADE
      -A POSTROUTING -s {{ nas_link_subnet }} -o eno1 -j MASQUERADE
      COMMIT
  notify: reload ufw

- name: Allow SSH from NAS
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp
    src: "{{ nas_link_nas_ip }}"
    comment: "SSH from NAS"
```

- [ ] **Step 4: Create node1 handlers**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-node1/handlers/main.yml
---
- name: apply netplan
  command: netplan apply

- name: reload ufw
  community.general.ufw:
    state: reloaded
```

- [ ] **Step 5: Create NAS role — netplan template**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-nas/templates/00-eno1.yaml.j2
network:
  version: 2
  renderer: networkd
  ethernets:
    {{ nas_link_nas_interface }}:
      match:
        macaddress: {{ nas_link_nas_mac }}
      set-name: {{ nas_link_nas_interface }}
      addresses:
        - {{ nas_link_nas_ip }}/{{ nas_link_cidr }}
      routes:
        - to: default
          via: {{ nas_link_node1_ip }}
      nameservers:
        addresses:
          - 1.1.1.1
```

- [ ] **Step 6: Create NAS role — tasks**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-nas/tasks/main.yml
---
- name: Deploy NAS netplan config
  template:
    src: 00-eno1.yaml.j2
    dest: /etc/netplan/00-eno1.yaml
    owner: root
    group: root
    mode: "0600"
  notify: apply netplan nas

- name: Install Docker prerequisites
  apt:
    name:
      - docker.io
      - docker-compose-v2
      - python3-docker
    state: present
    update_cache: true

- name: Enable and start Docker
  systemd:
    name: docker
    enabled: true
    state: started

- name: Install UFW
  apt:
    name: ufw
    state: present

- name: Allow SSH
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp

- name: Allow PostgreSQL from homelab
  community.general.ufw:
    rule: allow
    port: "5432"
    proto: tcp
    src: "{{ item }}"
    comment: "PostgreSQL from homelab"
  loop:
    - "{{ nas_link_node1_ip }}"
    - "{{ node1_ip }}"
    - "{{ node2_ip }}"

- name: Allow MariaDB from homelab
  community.general.ufw:
    rule: allow
    port: "3306"
    proto: tcp
    src: "{{ item }}"
    comment: "MariaDB from homelab"
  loop:
    - "{{ nas_link_node1_ip }}"
    - "{{ node1_ip }}"
    - "{{ node2_ip }}"

- name: Allow Redis from homelab
  community.general.ufw:
    rule: allow
    port: "6379"
    proto: tcp
    src: "{{ item }}"
    comment: "Redis from homelab"
  loop:
    - "{{ nas_link_node1_ip }}"
    - "{{ node1_ip }}"
    - "{{ node2_ip }}"

- name: Enable UFW
  community.general.ufw:
    state: enabled
    default: deny
```

- [ ] **Step 7: Create NAS handlers**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-nas/handlers/main.yml
---
- name: apply netplan nas
  command: netplan apply
```

- [ ] **Step 8: Create route role for node2**

```yaml
# infrastructure/nas-link-setup/roles/nas-link-route/tasks/main.yml
---
- name: Create networkd drop-in directory
  file:
    path: /etc/systemd/network/10-nas-route.network.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Add persistent route to NAS via node1
  copy:
    content: |
      [Route]
      Destination={{ nas_link_subnet }}
      Gateway={{ node1_ip }}
    dest: /etc/systemd/network/10-nas-route.network.d/nas-route.conf
    owner: root
    group: root
    mode: "0644"
  register: route_added

- name: Add temporary route (immediate)
  command: ip route add {{ nas_link_subnet }} via {{ node1_ip }}
  ignore_errors: true
  when: route_added.changed
```

- [ ] **Step 9: Create main setup.yml**

```yaml
# infrastructure/nas-link-setup/setup.yml
---
- name: Configure NAS direct link — Node1 side
  hosts: node1
  become: true
  roles:
    - nas-link-node1

- name: Configure NAS direct link — NAS side
  hosts: nas
  become: true
  roles:
    - nas-link-nas

- name: Configure route to NAS — Node2
  hosts: node2
  become: true
  roles:
    - nas-link-route
```

- [ ] **Step 10: Create inventory**

```ini
# infrastructure/nas-link-setup/inventory/hosts.ini
[node1]
192.168.0.105 ansible_user=kamil-rybacki

[nas]
10.0.1.2 ansible_user=kamil

[node2]
192.168.0.108 ansible_user=kamil
```

- [ ] **Step 11: Commit**

```bash
git add infrastructure/nas-link-setup/
git commit -m "feat(infra): add NAS direct link automation playbook"
```

### Task 1.2: Test NAS link playbook

- [ ] **Step 1: Verify NAS is reachable**

```bash
ssh kamil@10.0.1.2 "hostname && ip addr show eno1 | grep inet"
```
Expected: `lw35` and `10.0.1.2/24`

- [ ] **Step 2: Dry-run the playbook**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  infrastructure/nas-link-setup/setup.yml \
  -i infrastructure/nas-link-setup/inventory/hosts.ini \
  --check --diff
```
Expected: shows planned changes without applying

- [ ] **Step 3: Verify NAS internet access**

```bash
ssh kamil@10.0.1.2 "ping -c 1 -W 2 8.8.8.8 && ping -c 1 -W 2 192.168.0.108"
```
Expected: both pings succeed (NAS can reach internet and node2)

---

## Phase 2: Update All Hardcoded 10.0.0.x IPs

### Task 2.1: Update shared database defaults and bind addresses

**Files:**
- Modify: `common/shared-database/defaults.yml:4`
- Modify: `common/shared-database/detect.yml:5`
- Modify: `infrastructure/shared-postgres-setup/group_vars/all.yml:7`
- Modify: `infrastructure/shared-mariadb-setup/group_vars/all.yml:6`
- Modify: `infrastructure/shared-redis-setup/group_vars/all.yml:6`

- [ ] **Step 1: Update shared DB host default**

In `common/shared-database/defaults.yml:4`:
```yaml
# Old:
shared_db_host: "10.0.0.2"
# New:
shared_db_host: "10.0.1.2"
```

- [ ] **Step 2: Update detect.yml comment**

In `common/shared-database/detect.yml:5`:
```yaml
# Old:
#   shared_db_host   – IP of the shared DB node (default: 10.0.0.2)
# New:
#   shared_db_host   – IP of the shared DB node (default: 10.0.1.2)
```

- [ ] **Step 3: Update postgres bind address**

In `infrastructure/shared-postgres-setup/group_vars/all.yml:7`:
```yaml
# Old:
shared_postgres_bind_address: "10.0.0.2"
# New:
shared_postgres_bind_address: "10.0.1.2"
```

- [ ] **Step 4: Update mariadb bind address**

In `infrastructure/shared-mariadb-setup/group_vars/all.yml:6`:
```yaml
# Old:
shared_mariadb_bind_address: "10.0.0.2"
# New:
shared_mariadb_bind_address: "10.0.1.2"
```

- [ ] **Step 5: Update redis bind address**

In `infrastructure/shared-redis-setup/group_vars/all.yml:6`:
```yaml
# Old:
shared_redis_bind_address: "10.0.0.2"
# New:
shared_redis_bind_address: "10.0.1.2"
```

- [ ] **Step 6: Commit**

```bash
git add common/shared-database/ infrastructure/shared-postgres-setup/group_vars/ \
  infrastructure/shared-mariadb-setup/group_vars/ infrastructure/shared-redis-setup/group_vars/
git commit -m "fix(infra): update shared DB host and bind addresses to NAS IP 10.0.1.2"
```

### Task 2.2: Update all vars_prompt defaults

**Files:**
- Modify: `infrastructure/shared-postgres-setup/setup.yml:40`
- Modify: `infrastructure/shared-mariadb-setup/setup.yml:39`
- Modify: `infrastructure/shared-redis-setup/setup.yml:39`
- Modify: `infrastructure/service-startup-setup/setup.yml:16`
- Modify: `infrastructure/migrate-to-shared/migrate.yml:14`
- Modify: `infrastructure/migrate-to-shared/cleanup.yml:14`
- Modify: `infrastructure/netbox-agent-setup/setup.yml:58`

- [ ] **Step 1: Update all 6 setup.yml files**

In each file, change `default: "10.0.0.2"` to `default: "10.0.1.2"`:

```bash
# All files with the same change:
sed -i 's/default: "10.0.0.2"/default: "10.0.1.2"/g' \
  infrastructure/shared-postgres-setup/setup.yml \
  infrastructure/shared-mariadb-setup/setup.yml \
  infrastructure/shared-redis-setup/setup.yml \
  infrastructure/service-startup-setup/setup.yml \
  infrastructure/migrate-to-shared/migrate.yml \
  infrastructure/migrate-to-shared/cleanup.yml
```

- [ ] **Step 2: Update netbox-agent-setup example IP**

In `infrastructure/netbox-agent-setup/setup.yml:58`, change example:
```yaml
# Old:
        (comma-separated, e.g. 10.0.0.2,10.0.0.3)
# New:
        (comma-separated, e.g. 192.168.0.108,192.168.0.107)
```

And line 68:
```yaml
# Old:
      prompt: "[3/4] NetBox URL (e.g. http://10.0.0.5:8081)"
# New:
      prompt: "[3/4] NetBox URL (e.g. http://192.168.0.105:8081)"
```

- [ ] **Step 3: Verify no remaining 10.0.0 references**

```bash
grep -rn "10\.0\.0\." --include="*.yml" --include="*.yaml" --include="*.j2" --include="*.ini" \
  infrastructure/ common/ | grep -v ".git"
```
Expected: no matches

- [ ] **Step 4: Commit**

```bash
git add infrastructure/ common/
git commit -m "fix(infra): update all vars_prompt defaults from 10.0.0.2 to 10.0.1.2"
```

### Task 2.3: Update security configs (Authelia, Caddy UFW)

**Files:**
- Modify: `security/secure-homelab-access/roles/authelia/templates/configuration.yml.j2:30`
- Modify: `security/secure-homelab-access/roles/caddy/tasks/main.yml:87-92`

- [ ] **Step 1: Narrow Authelia network rule**

In `security/secure-homelab-access/roles/authelia/templates/configuration.yml.j2:30`:
```yaml
# Old:
        - "10.0.0.0/8"         # LAN (homelab nodes)
# New:
        - "10.0.1.0/24"        # NAS direct link
```

- [ ] **Step 2: Narrow Caddy UFW rule**

In `security/secure-homelab-access/roles/caddy/tasks/main.yml:87-92`:
```yaml
# Old:
- name: Allow Caddy metrics from LAN (10.0.0.0/8)
  community.general.ufw:
    rule: allow
    port: "2019"
    proto: tcp
    src: 10.0.0.0/8
    comment: "Caddy admin metrics for Alloy"
# New:
- name: Allow Caddy metrics from NAS link (10.0.1.0/24)
  community.general.ufw:
    rule: allow
    port: "2019"
    proto: tcp
    src: 10.0.1.0/24
    comment: "Caddy admin metrics for Alloy"
```

- [ ] **Step 3: Narrow Grafana stack UFW rules**

In `monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml:22`:
```yaml
# Old:
- name: Allow Loki from LAN (10.0.0.0/8)
  community.general.ufw:
    ...
    src: 10.0.0.0/8
# New:
- name: Allow Loki from NAS link (10.0.1.0/24)
  community.general.ufw:
    ...
    src: 10.0.1.0/24
```

In same file line 38:
```yaml
# Old:
- name: Allow Mimir from LAN (10.0.0.0/8)
  community.general.ufw:
    ...
    src: 10.0.0.0/8
# New:
- name: Allow Mimir from NAS link (10.0.1.0/24)
  community.general.ufw:
    ...
    src: 10.0.1.0/24
```

- [ ] **Step 4: Update Alloy agent setup example IPs**

In `monitoring/alloy-agent-setup/setup.yml:30`:
```yaml
# Old:
        (comma-separated, e.g. 10.0.0.2,10.0.0.3)
# New:
        (comma-separated, e.g. 192.168.0.108,10.0.1.2)
```

In same file line 40:
```yaml
# Old:
        (e.g. 10.0.0.1)
# New:
        (e.g. 192.168.0.105)
```

- [ ] **Step 5: Commit**

```bash
git add security/secure-homelab-access/roles/authelia/ security/secure-homelab-access/roles/caddy/ \
  monitoring/grafana-stack-setup/roles/grafana-stack/tasks/ monitoring/alloy-agent-setup/
git commit -m "fix(security): narrow all 10.0.0.0/8 UFW rules to 10.0.1.0/24, update monitoring IPs"
```

### Task 2.4: Update dev-tools and monitoring references

**Files:**
- Modify: `dev-tools/nexterm-setup/group_vars/all.yml:32,36`
- Modify: `dev-tools/paperless-mcp-setup/group_vars/all.yml:3`
- Modify: `dev-tools/github-runner-setup/inventory/hosts.ini:2`

- [ ] **Step 1: Update Nexterm connections**

In `dev-tools/nexterm-setup/group_vars/all.yml`:
```yaml
# Old (lines 31, 35):
    ip: "10.0.0.1"
    ip: "10.0.0.2"
# New:
    ip: "192.168.0.105"
    ip: "192.168.0.108"
```

- [ ] **Step 2: Update Paperless MCP URL**

In `dev-tools/paperless-mcp-setup/group_vars/all.yml:3`:
```yaml
# Old:
paperless_api_url: "http://10.0.0.2:8000"
# New:
paperless_api_url: "http://10.0.1.2:8000"
```

- [ ] **Step 3: Update GitHub runner inventory**

In `dev-tools/github-runner-setup/inventory/hosts.ini`:
```ini
# Old:
10.0.0.2 ansible_user=kamil ansible_ssh_private_key_file=~/.ssh/id_ed25519
# New:
192.168.0.108 ansible_user=kamil ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

- [ ] **Step 4: Commit**

```bash
git add dev-tools/
git commit -m "fix(dev-tools): update all 10.0.0.x references to new IPs"
```

### Task 2.5: Final sweep — verify zero remaining 10.0.0.x references

- [ ] **Step 1: Full repo grep**

```bash
grep -rn "10\.0\.0\." --include="*.yml" --include="*.yaml" --include="*.j2" --include="*.ini" \
  infrastructure/ common/ security/ monitoring/ automation/ dev-tools/ files/ ai/ \
  | grep -v "docs/"
```
Expected: zero functional matches (comments in setup.yml files about old topology are acceptable)

- [ ] **Step 2: Commit any stragglers**

If any found, fix and commit with:
```bash
git commit -m "fix: remove remaining 10.0.0.x references"
```

---

## Phase 3: Deploy Databases on NAS

### Task 3.1: Deploy shared PostgreSQL on NAS

- [ ] **Step 1: Run shared-postgres playbook targeting NAS**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  infrastructure/shared-postgres-setup/setup.yml
```
When prompted: enter `10.0.1.2` for target host, `kamil` for SSH user.

- [ ] **Step 2: Verify PostgreSQL is running on NAS**

```bash
ssh kamil@10.0.1.2 "docker ps | grep shared-postgres"
```
Expected: container running, healthy

- [ ] **Step 3: Verify connectivity from node1**

```bash
psql -h 10.0.1.2 -U postgres -c "SELECT version();"
```
Expected: PostgreSQL 16.x version string

### Task 3.2: Deploy shared MariaDB on NAS

- [ ] **Step 1: Run shared-mariadb playbook targeting NAS**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  infrastructure/shared-mariadb-setup/setup.yml
```
When prompted: enter `10.0.1.2` for target host, `kamil` for SSH user.

- [ ] **Step 2: Verify MariaDB running**

```bash
ssh kamil@10.0.1.2 "docker ps | grep shared-mariadb"
```

### Task 3.3: Deploy shared Redis on NAS

- [ ] **Step 1: Run shared-redis playbook targeting NAS**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  infrastructure/shared-redis-setup/setup.yml
```
When prompted: enter `10.0.1.2` for target host, `kamil` for SSH user.

- [ ] **Step 2: Verify Redis running**

```bash
ssh kamil@10.0.1.2 "docker ps | grep shared-redis"
```

### Task 3.4: Migrate data from node2 to NAS

- [ ] **Step 1: Dump PostgreSQL on node2**

```bash
ssh kamil@192.168.0.108 "docker exec shared-postgres pg_dumpall -U postgres > /tmp/pg_dump.sql"
scp kamil@192.168.0.108:/tmp/pg_dump.sql /tmp/
scp /tmp/pg_dump.sql kamil@10.0.1.2:/tmp/
```

- [ ] **Step 2: Restore PostgreSQL on NAS**

```bash
ssh kamil@10.0.1.2 "docker exec -i shared-postgres psql -U postgres < /tmp/pg_dump.sql"
```

- [ ] **Step 3: Dump and restore MariaDB**

```bash
ssh kamil@192.168.0.108 "docker exec shared-mariadb mysqldump -u root --all-databases > /tmp/maria_dump.sql"
scp kamil@192.168.0.108:/tmp/maria_dump.sql /tmp/
scp /tmp/maria_dump.sql kamil@10.0.1.2:/tmp/
ssh kamil@10.0.1.2 "docker exec -i shared-mariadb mysql -u root < /tmp/maria_dump.sql"
```

- [ ] **Step 4: Dump and restore Redis**

```bash
ssh kamil@192.168.0.108 "docker exec shared-redis redis-cli BGSAVE && sleep 2 && docker cp shared-redis:/data/dump.rdb /tmp/"
scp kamil@192.168.0.108:/tmp/dump.rdb /tmp/
scp /tmp/dump.rdb kamil@10.0.1.2:/tmp/
ssh kamil@10.0.1.2 "docker cp /tmp/dump.rdb shared-redis:/data/ && docker restart shared-redis"
```

- [ ] **Step 5: Verify data integrity**

```bash
# Compare row counts for critical tables
ssh kamil@192.168.0.108 "docker exec shared-postgres psql -U postgres -d netbox -c 'SELECT count(*) FROM dcim_device;'"
ssh kamil@10.0.1.2 "docker exec shared-postgres psql -U postgres -d netbox -c 'SELECT count(*) FROM dcim_device;'"
# Counts must match
```

- [ ] **Step 6: Verify node2 can reach NAS databases via static route**

```bash
ssh kamil@192.168.0.108 "ping -c 1 -W 2 10.0.1.2 && \
  docker run --rm postgres:16-alpine pg_isready -h 10.0.1.2 -p 5432"
```
Expected: ping succeeds, pg_isready reports "accepting connections"

- [ ] **Step 7: Stop old databases on node2 (keep containers, don't remove)**

```bash
ssh kamil@192.168.0.108 "docker stop shared-postgres shared-mariadb shared-redis"
```

---

## Phase 4: Move Paperless to NAS

### Task 4.1: Deploy Paperless on NAS

- [ ] **Step 1: Copy Paperless data from node2**

```bash
ssh kamil@192.168.0.108 "sudo tar czf /tmp/paperless-data.tar.gz -C /opt paperless"
scp kamil@192.168.0.108:/tmp/paperless-data.tar.gz /tmp/
scp /tmp/paperless-data.tar.gz kamil@10.0.1.2:/tmp/
ssh kamil@10.0.1.2 "sudo tar xzf /tmp/paperless-data.tar.gz -C /opt"
```

- [ ] **Step 2: Run Paperless playbook targeting NAS**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  files/paperless-setup/setup.yml
```
When prompted: enter `10.0.1.2` for target host, `kamil` for SSH user.

- [ ] **Step 3: Verify Paperless running on NAS**

```bash
ssh kamil@10.0.1.2 "docker ps | grep paperless"
curl -s -o /dev/null -w '%{http_code}' http://10.0.1.2:8000
```
Expected: container running, HTTP 200 (or 302 redirect)

- [ ] **Step 4: Stop Paperless on node2**

```bash
ssh kamil@192.168.0.108 "docker stop paperless"
```

---

## Phase 5: Move Netbox to Node1

### Task 5.1: Deploy Netbox on node1

- [ ] **Step 1: Run Netbox playbook targeting localhost**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  monitoring/netbox-setup/setup.yml
```
When prompted: enter `localhost` for target, `kamil-rybacki` for SSH user. Database host: `10.0.1.2`.

- [ ] **Step 2: Verify Netbox running on node1**

```bash
docker ps | grep netbox
curl -s -o /dev/null -w '%{http_code}' http://localhost:8081
```
Expected: container running, HTTP 200/302

- [ ] **Step 3: Stop Netbox on node2**

```bash
ssh kamil@192.168.0.108 "docker stop netbox netbox-worker netbox-housekeeping"
```

---

## Phase 6: Update Caddy and Remaining Configs

### Task 6.1: Redeploy secure-homelab-access stack

This redeploys Caddy, Authelia, Homepage with updated configs.

- [ ] **Step 1: Run secure-homelab-access playbook**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  security/secure-homelab-access/setup.yml
```
This applies the updated Authelia network rules and Caddy UFW rules from Phase 2.

- [ ] **Step 2: Verify Caddy is proxying correctly**

```bash
# Test each service through Cloudflare tunnel
curl -s -o /dev/null -w '%{http_code}' https://n8n.kamilandrzejrybacki.dpdns.org
curl -s -o /dev/null -w '%{http_code}' https://netbox.kamilandrzejrybacki.dpdns.org
curl -s -o /dev/null -w '%{http_code}' https://paperless.kamilandrzejrybacki.dpdns.org
curl -s -o /dev/null -w '%{http_code}' https://home.kamilandrzejrybacki.dpdns.org
```
Expected: all return 200 or 302

### Task 6.2: Redeploy services with dynamic Caddy routes

Each of these playbooks appends its own Caddy route. Re-running updates the proxy targets.

- [ ] **Step 1: Re-run n8n playbook**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  automation/n8n-setup/setup.yml
```

- [ ] **Step 2: Re-run Paperless playbook (updates Caddy route to NAS)**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook \
  files/paperless-setup/setup.yml
```
When prompted: enter `10.0.1.2` for target host.

- [ ] **Step 3: Verify both accessible**

```bash
curl -s -o /dev/null -w '%{http_code}' https://n8n.kamilandrzejrybacki.dpdns.org
curl -s -o /dev/null -w '%{http_code}' https://paperless.kamilandrzejrybacki.dpdns.org
```

### Task 6.3: Restart all containers to clear DNS caches

- [ ] **Step 1: Restart node1 services**

```bash
docker restart caddy authelia homepage
```

- [ ] **Step 2: Restart node2 services**

```bash
ssh kamil@192.168.0.108 "docker restart n8n"
```

- [ ] **Step 3: Restart NAS services**

```bash
ssh kamil@10.0.1.2 "docker restart paperless shared-postgres shared-redis shared-mariadb"
```

- [ ] **Step 4: Commit all remaining changes**

```bash
git add -A
git status  # review what's staged
git commit -m "feat: complete network migration to 192.168.0.x/10.0.1.x"
```

---

## Phase 7: Node2 Cleanup

### Task 7.1: Remove migrated services from node2

- [ ] **Step 1: Verify all services work from new locations**

```bash
# Databases on NAS
psql -h 10.0.1.2 -U postgres -c "SELECT 1;"
# Paperless on NAS
curl -s -o /dev/null -w '%{http_code}' http://10.0.1.2:8000
# Netbox on node1
curl -s -o /dev/null -w '%{http_code}' http://localhost:8081
# n8n on node2
curl -s -o /dev/null -w '%{http_code}' http://192.168.0.108:5678
```

- [ ] **Step 2: Remove stopped containers and volumes on node2**

```bash
ssh kamil@192.168.0.108 "docker rm shared-postgres shared-mariadb shared-redis \
  netbox netbox-worker netbox-housekeeping paperless"
```

- [ ] **Step 3: Remove unused Docker networks on node2**

```bash
ssh kamil@192.168.0.108 "docker network prune -f"
```

- [ ] **Step 4: Node2 final state verification**

```bash
ssh kamil@192.168.0.108 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```
Expected: only `n8n`, `n8n-vault-shim`, `github-runner`, `docker-exporter`, `claude-backup-redis`

---

## Post-Migration Checklist

- [ ] All 4 nodes reachable via SSH
- [ ] Cloudflare Tunnel serving all subdomains (HTTP 200/302)
- [ ] Homepage dashboard shows all services green
- [ ] n8n workflows executing (check recent executions)
- [ ] Paperless documents accessible and searchable
- [ ] Netbox devices/racks visible
- [ ] Grafana dashboards loading with fresh metrics
- [ ] WireGuard VPN connects and reaches services with single-factor auth
- [ ] No `10.0.0.x` references remain in codebase (except docs)

---

## Future Work (Not In This Plan)

- **Phase 7b:** Deploy Seafile on NAS (requires `files/seafile-setup/` refactoring — separate plan)
- **Phase 7c:** Deploy Dify on node2 (separate plan)
- **Phase 8:** Proxmox on lw-c1, OpenClaw/Ollama migration (separate plan)
- **Alloy agent on NAS:** Deploy monitoring agent (separate plan)
- **NAS backup strategy:** Scheduled pg_dumpall/mysqldump to node1 via cron
- **Memory files update:** Update `project_homelab_node1.md`, `project_homelab_node2.md`
