# Knowledge Vault Viewer — Syncthing + Quartz

**Date:** 2026-03-26
**Status:** Approved
**Category:** files/
**Depends on:** obsidian-livesync-setup (CouchDB already deployed)

## Summary

Deploy Syncthing + Quartz on the shared database host (10.0.1.2) to provide a private, Authelia-protected web viewer for an Obsidian vault. Syncthing receives the vault folder from the user's Linux desktop. Quartz watches the folder and auto-rebuilds a static site. Replaces the CouchDB Fauxton Homepage entry with a "Knowledge Vault" link.

## Requirements

- Syncthing container receiving vault files from Linux desktop
- Quartz container rendering vault as a browsable website with graph view, backlinks, search
- Auto-rebuild on file change (Quartz watch mode)
- Accessible at `kb.<domain>` behind Authelia
- Replace existing "Obsidian Sync" Homepage entry with "Knowledge Vault"
- Pi-hole DNS, Cloudflare Tunnel, Caddy integration
- Vault secrets in HashiCorp Vault
- Coexists with LiveSync + CouchDB (mobile editing unchanged)

## Architecture

### Components (all on 10.0.1.2)

- **Syncthing container** — receives vault folder from Linux desktop via P2P sync
- **Quartz container** — custom image, watches shared volume, auto-rebuilds static site
- **Shared Docker volume** (`vault-content`) — Syncthing writes, Quartz reads
- **Caddy reverse proxy** — `kb.<domain>` behind Authelia → Quartz port 8080

### Data Flow

```
Linux Desktop (Obsidian + Syncthing)
  → Syncthing P2P → Syncthing container (10.0.1.2)
    → shared volume (vault-content)
      → Quartz container (watches, auto-rebuilds)
        → static site on port 8080
          → Caddy (kb.<domain>, Authelia-protected)
```

### Relationship with LiveSync

```
Desktop Obsidian ──LiveSync──→ CouchDB ──→ Mobile Obsidian (edit)
       │
       └──Syncthing──→ vault-content volume ──→ Quartz ──→ Browser (read-only)
```

LiveSync + CouchDB handles mobile editing. Syncthing + Quartz provides a read-only web viewer accessible from any device.

### Security

- Quartz site behind Authelia (private, no public access)
- Syncthing Web UI bound to localhost only (admin access via SSH tunnel)
- Syncthing device pairing requires manual approval
- Syncthing admin password stored in Vault

## Playbook Structure

```
files/knowledge-vault-setup/
├── setup.yml                    # Main playbook (vars_prompt)
├── group_vars/all.yml           # Images, ports, paths, defaults
├── inventory/hosts.ini          # Empty, dynamic
└── roles/
    ├── syncthing/
    │   ├── tasks/main.yml       # Deploy Syncthing container
    │   ├── defaults/main.yml
    │   ├── templates/
    │   │   └── docker-compose.yml.j2
    │   └── molecule/default/
    ├── quartz/
    │   ├── tasks/main.yml       # Build + deploy Quartz container
    │   ├── defaults/main.yml
    │   ├── templates/
    │   │   ├── docker-compose.yml.j2
    │   │   ├── Dockerfile.j2
    │   │   └── quartz.config.ts.j2
    │   └── molecule/default/
    └── docker/
        ├── defaults/main.yml
        └── tasks/main.yml       # Reuse standard Docker installation
```

## Syncthing Configuration

### Container

- **Image:** `syncthing/syncthing:latest`
- **Ports:** `22000:22000/tcp` (sync), `22000:22000/udp` (QUIC), `127.0.0.1:8384:8384` (Web UI, localhost only)
- **Volumes:** `vault-content:/var/syncthing/vault`, `syncthing-config:/var/syncthing/config`
- **Network:** `vault-net`
- **Restart:** `unless-stopped`
- **Environment:** `PUID=1000`, `PGID=1000`

### Post-Deploy

- Wait for Syncthing API to become healthy
- Set admin password via Syncthing REST API
- Print device ID in playbook output for desktop pairing

## Quartz Configuration

### Container

- **Custom Dockerfile** built from Quartz repo
- **Command:** `npx quartz build --serve --port 8080`
- **Ports:** `8080:8080`
- **Volumes:** `vault-content:/usr/src/app/content:ro` (read-only)
- **Network:** `vault-net`
- **Restart:** `unless-stopped`

### Dockerfile

```dockerfile
FROM node:22-slim AS builder
WORKDIR /usr/src/app
RUN git clone --depth 1 https://github.com/jackyzha0/quartz.git . && npm ci
COPY quartz.config.ts /usr/src/app/quartz.config.ts
EXPOSE 8080
CMD ["npx", "quartz", "build", "--serve", "--port", "8080"]
```

### quartz.config.ts

- `baseUrl`: `kb.<domain>`
- `pageTitle`: "Knowledge Vault"
- `enableSPA`: true
- `analytics`: none (private)
- Default plugins: graph view, backlinks, search, explorer, table of contents

## Caddy Integration

### Caddyfile Block

```
http://kb.{{ saved_domain }} {
  import rate_limit
  import proxy_headers
  import authelia
  reverse_proxy http://10.0.1.2:8080
}
```

Added via `blockinfile` with marker `# {mark} KNOWLEDGE_VAULT`.

### DNS

- Cloudflare Tunnel: `kb.<domain>` route
- Pi-hole: `kb.<domain>` → gateway IP

### Homepage

Replace `# {mark} OBSIDIAN_LIVESYNC` entry with `# {mark} KNOWLEDGE_VAULT`:

```yaml
- Knowledge Vault:
    icon: obsidian.png
    href: "https://kb.<domain>"
    description: "Personal knowledge base"
```

## Vault Secrets

Path: `secret/homelab/knowledge-vault`

| Key | Description |
|-----|-------------|
| `syncthing_admin_password` | Syncthing Web UI admin password |

## Playbook vars_prompt

```
[1/3] IP or hostname of the target host (default: 10.0.1.2)
[2/3] SSH user for the target host
[3/3] Syncthing admin password
```

Follows existing pattern: check saved vars → check Vault → prompt interactively.

## Testing (Molecule)

### Syncthing role
- Container is running and healthy
- Port 22000 is listening (sync protocol)
- Port 8384 is listening on localhost (Web UI)
- Syncthing API responds at `/rest/system/status`
- vault-content volume exists

### Quartz role
- Container is running
- Port 8080 is listening
- HTTP GET returns HTML with "Knowledge Vault" title
- vault-content volume is mounted read-only

## Client Setup (One-time, manual)

1. Install Syncthing on Linux desktop (`apt install syncthing`)
2. Copy server device ID from playbook output
3. Add server device in desktop Syncthing UI (`localhost:8384`)
4. Share Obsidian vault folder with server device
5. Accept share on server Syncthing (pre-approved by playbook if possible)

## Backup

No dedicated backup needed — the source of truth is the desktop vault folder. Syncthing provides file versioning. Quartz output is ephemeral (rebuilt from source).
