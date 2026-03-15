# Homelab Services — Pi-hole, Uptime Kuma, Vaultwarden, Paperless-ngx

**Date:** 2026-03-15
**Status:** Approved

## Overview

Add 4 new homelab service playbooks to the Ansible repository:

1. **Pi-hole** — integrated as a new role in `infrastructure/secure-homelab-access`
2. **Uptime Kuma** — standalone playbook at `home-services/kuma-setup/`
3. **Vaultwarden** — standalone playbook at `home-services/vaultwarden-setup/`
4. **Paperless-ngx** — standalone playbook at `home-services/paperless-setup/`

## Design Decisions

- Pi-hole is integrated into the existing secure-homelab-access playbook because it is tightly coupled to WireGuard DNS and benefits from Caddy + Authelia protection.
- The other 3 services are independent playbooks that can be deployed to any host.
- All containers bind to `127.0.0.1` (localhost only) for security.
- All container images are pinned to specific versions (no `:latest`).
- All secret-handling tasks use `no_log: true`.
- All playbooks use interactive `vars_prompt` setup wizards consistent with existing playbooks.

## 1. Pi-hole — `infrastructure/secure-homelab-access`

### New role: `pihole`

**Container:** `pihole/pihole:<pinned-version>`

**Group vars additions:**
```yaml
# -- Pi-hole (DNS) -----------------------------------------------------------
pihole_container_name: "pihole"
pihole_data_dir: "{{ docker_data_dir }}/pihole"
pihole_web_port: 8053
subdomain_pihole: "pihole"
```

**Setup wizard:** Adds prompt `[9/9]` for the Pi-hole admin password (private, confirmed).

**Integration with existing roles:**

- **WireGuard**: `wireguard_dns` changes from `1.1.1.1,1.0.0.1` to the Pi-hole container's IP on the `homelab-net` Docker network. The Pi-hole container joins the same Docker network.
- **Caddy**: Adds `{{ subdomain_pihole }}.{{ domain }}` site block with `import authelia` and `reverse_proxy` to Pi-hole's web interface.
- **Homepage**: Adds Pi-hole entry to the Infrastructure section in `services.yaml.j2`.
- **Authelia**: No changes — the existing `*.{{ domain }}` wildcard two_factor rule covers Pi-hole.

**Role tasks:**
1. Create data directories (`{{ pihole_data_dir }}/etc-pihole`, `{{ pihole_data_dir }}/etc-dnsmasq.d`)
2. Deploy Pi-hole container on `homelab-net` with:
   - `WEBPASSWORD` set from prompted password
   - DNS ports `53:53/tcp` and `53:53/udp` bound on the host
   - Web UI on internal port only (not published — accessed via Caddy)
   - Volumes for persistent config
3. Health check: wait for Pi-hole API to respond

**Dependencies:** `docker` role (already in the playbook)

## 2. Uptime Kuma — `home-services/kuma-setup/`

### Structure
```
home-services/kuma-setup/
├── setup.yml
├── inventory/hosts.ini
├── group_vars/all.yml
└── roles/
    ├── docker/        (copied from existing pattern)
    └── kuma/
        ├── defaults/main.yml
        ├── meta/main.yml
        └── tasks/main.yml
```

### Setup wizard prompts
1. Host IP or hostname
2. SSH user

### Group vars
```yaml
kuma_container_name: kuma
kuma_image: "louislam/uptime-kuma:1"
kuma_port: 3001
kuma_volume_name: kuma_data
kuma_restart_policy: unless-stopped
```

### Role tasks
1. Create Docker volume
2. Deploy Uptime Kuma container, port bound to `127.0.0.1:{{ kuma_port }}:3001`
3. Health check: wait for web UI to respond
4. Display access URL

**Note:** Uptime Kuma handles its own account setup via the web UI on first launch. No API-based account creation needed.

## 3. Vaultwarden — `home-services/vaultwarden-setup/`

### Structure
```
home-services/vaultwarden-setup/
├── setup.yml
├── inventory/hosts.ini
├── group_vars/all.yml
└── roles/
    ├── docker/        (copied from existing pattern)
    └── vaultwarden/
        ├── defaults/main.yml
        ├── meta/main.yml
        └── tasks/main.yml
```

### Setup wizard prompts
1. Host IP or hostname
2. SSH user
3. Admin token (private, confirmed) — used for the `/admin` panel

### Group vars
```yaml
vaultwarden_container_name: vaultwarden
vaultwarden_image: "vaultwarden/server:1.32"
vaultwarden_port: 8080
vaultwarden_data_dir: /opt/vaultwarden
vaultwarden_restart_policy: unless-stopped
```

### Role tasks
1. Create data directory with mode `0700`
2. Generate argon2id hash of the admin token using `openssl` or the container's built-in hasher
3. Deploy Vaultwarden container with environment:
   - `SIGNUPS_ALLOWED=false`
   - `ADMIN_TOKEN={{ hashed_admin_token }}`
   - `ROCKET_PORT=80`
   - `no_log: true` on the container task
4. Port bound to `127.0.0.1:{{ vaultwarden_port }}:80`
5. Volume: `{{ vaultwarden_data_dir }}:/data`
6. Health check: wait for web UI
7. Display access URL and admin panel URL

## 4. Paperless-ngx — `home-services/paperless-setup/`

### Structure
```
home-services/paperless-setup/
├── setup.yml
├── inventory/hosts.ini
├── group_vars/all.yml
├── roles/
│   ├── docker/        (copied from existing pattern)
│   └── paperless/
│       ├── defaults/main.yml
│       ├── meta/main.yml
│       ├── tasks/main.yml
│       └── templates/
│           └── docker-compose.yml.j2
└── (no additional templates)
```

### Setup wizard prompts
1. Host IP or hostname
2. SSH user
3. Admin username
4. Admin password (private, confirmed)
5. Document storage path (default: empty — uses Docker volume)

### Group vars
```yaml
paperless_container_name: paperless
paperless_image: "ghcr.io/paperless-ngx/paperless-ngx:2.14"
paperless_port: 8000
paperless_data_dir: /opt/paperless
paperless_document_path: ""  # Empty = Docker volume, set path for NAS/external
paperless_redis_image: "redis:7"
paperless_postgres_image: "postgres:16"
paperless_restart_policy: unless-stopped
```

### Docker Compose template

Paperless-ngx requires Redis + PostgreSQL. Uses a `docker-compose.yml.j2` template (same pattern as seafile-setup):

- **paperless-redis**: Redis container for task queue
- **paperless-db**: PostgreSQL container with auto-generated password
- **paperless-web**: Paperless-ngx container with:
  - `PAPERLESS_ADMIN_USER` and `PAPERLESS_ADMIN_PASSWORD` for superuser creation
  - `PAPERLESS_REDIS` pointing to Redis container
  - `PAPERLESS_DBHOST` pointing to PostgreSQL container
  - Port bound to `127.0.0.1:{{ paperless_port }}:8000`

**Storage logic:**
- If `paperless_document_path` is empty: Docker volume `paperless_media` mounted to `/usr/src/paperless/media`
- If `paperless_document_path` is set: bind mount that path to `/usr/src/paperless/media`

### Role tasks
1. Create data directories
2. Generate PostgreSQL password (auto, `no_log: true`)
3. Template `docker-compose.yml.j2` with mode `0600`
4. Deploy with `docker compose up -d`
5. Wait for health check
6. Display access URL

## README updates

Add all 4 new playbooks to the root `README.md` in their respective category tables.

## Security checklist

- [ ] No hardcoded secrets — all prompted or auto-generated
- [ ] `no_log: true` on all secret-handling tasks
- [ ] Containers bound to `127.0.0.1`
- [ ] Pinned image versions
- [ ] Docker Compose files mode `0600` (Paperless)
- [ ] Data directories restricted permissions
- [ ] Admin token hashed before storing (Vaultwarden)
