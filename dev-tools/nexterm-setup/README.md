# Nexterm Setup

Deploy [Nexterm](https://github.com/gnmyt/nexterm) — a lightweight, modern web-based SSH/terminal manager for accessing multiple homelab hosts from any browser.

## Overview

Nexterm provides a unified web interface for managing SSH connections to multiple servers without exposing SSH directly to the internet. It supports:

- **Web-based terminal access** to multiple hosts via SSH
- **Authelia OIDC SSO** — users authenticated through your homelab's 2FA system (no separate login)
- **Per-host SSH identities** — different usernames/keys for different target hosts
- **Auto-provisioning** — creates admin account, SSH identities, and host connections on first run

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Browser (User accessing nexterm.yourdomain.com)             │
└────────────────────────────┬────────────────────────────────┘
                             │ HTTPS
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Cloudflare Tunnel (terminating TLS)                         │
└────────────────────────────┬────────────────────────────────┘
                             │ HTTPS
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Caddy Reverse Proxy (rate_limit + authelia)                 │
│ Redirct to: http://127.0.0.1:6989 (internal HTTP)          │
└────────────────────────────┬────────────────────────────────┘
                             │ HTTP (internal only)
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Nexterm Container (with patched oidc.js)                    │
│ ├─ Receives HTTP requests from Caddy                        │
│ ├─ Contacts Authelia at http://authelia:9091 (internal)    │
│ └─ Uses per-host SSH keys to connect to target machines     │
└────────────────────────────┬────────────────────────────────┘
                             │ SSH
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Target Hosts (lw-main, lw-s1, etc.)                         │
│ Must have SSH public key in authorized_keys                 │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

Before running this playbook, you must:

1. **Secure homelab deployed** — `security/secure-homelab-access` must be running first (provides Authelia OIDC, Caddy reverse proxy)
2. **SSH key available on control node** — the playbook reads `~/.ssh/id_ed25519` and injects it into Nexterm
3. **SSH public key on all target hosts** — place `id_ed25519.pub` into `~/.ssh/authorized_keys` on each target host before running this playbook

### Example: Preparing target hosts

On each target host (e.g., `lw-main`), add the SSH public key:

```bash
# On control node, get the public key
cat ~/.ssh/id_ed25519.pub

# On target host, append to authorized_keys
echo "ssh-ed25519 AAAA... your-control-node" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Configuration

Edit `/home/kamil-rybacki/Code/ansible/dev-tools/nexterm-setup/group_vars/all.yml`:

```yaml
# Container settings
nexterm_container_name: nexterm
nexterm_image: germannewsmaker/nexterm:latest
nexterm_port: 6989
nexterm_bind_address: "127.0.0.1"
nexterm_data_dir: /opt/homelab/nexterm
nexterm_hostname: nexterm

# First-run bootstrap (admin account created once, then ignored)
nexterm_admin_username: admin
nexterm_admin_password: "changeme"
nexterm_admin_first_name: Kamil
nexterm_admin_last_name: Rybacki

# SSH key to inject (can be any Ed25519 key from your control node)
nexterm_ssh_key_path: "~/.ssh/id_ed25519"

# Hosts to pre-configure (creates one per-host SSH identity + connection)
nexterm_connections:
  - name: lw-main
    ip: "10.0.0.1"
    port: 22
    username: kamil-rybacki
  - name: lw-s1
    ip: "10.0.0.2"
    port: 22
    username: kamil
```

**Key points:**

- `nexterm_connections` — defines one entry per target host with its SSH username
- Each host gets its own named identity: `homelab-key-<hostname>` (e.g., `homelab-key-lw-main`)
- The playbook creates per-host SSH connections using these identities
- On first run, the playbook auto-registers the admin account and sets up all connections
- Subsequent runs are idempotent (skipped by checking `.bootstrapped` sentinel)

## Deployment

```bash
# Run the playbook (interactive wizard asks for no questions — uses defaults from group_vars)
ansible-playbook dev-tools/nexterm-setup/setup.yml \
  -i dev-tools/nexterm-setup/inventory/hosts.ini \
  --ask-become-pass

# Or, if secure-homelab-access is already running:
ansible-playbook dev-tools/nexterm-setup/setup.yml \
  -i dev-tools/nexterm-setup/inventory/hosts.ini
```

## What gets deployed

### 1. Nexterm Container

- **Image:** `germannewsmaker/nexterm:latest`
- **Port:** `127.0.0.1:6989` (internal only; exposed via Caddy)
- **Data directory:** `/opt/homelab/nexterm/` (persists DB, encryption keys, patches)
- **Restart policy:** `unless-stopped`

### 2. Encryption Key

The playbook generates a 64-character hex encryption key (via `openssl rand -hex 32`) and stores it at:

```
/opt/homelab/nexterm/.encryption_key
```

This key is read once per Nexterm startup and used to encrypt stored credentials. If lost, all stored secrets are unrecoverable.

### 3. Patched OIDC Controller (`oidc.js`)

The playbook ships a patched version of Nexterm's OIDC controller to handle a protocol mismatch:

**Problem:**
- Caddy (internal HTTP) advertises itself to Nexterm as `http://auth.yourdomain`
- But Authelia derives its issuer from `X-Forwarded-Proto` (HTTPS via Cloudflare TLS)
- The OpenID Connect `openid-client` library requires issuer URLs to match exactly between discovery and actual requests
- Result: validation fails because `https://...` != `http://...`

**Solution:**
The patched `oidc.js` (mounted read-only at `/app/server/controllers/oidc.js` inside the container):
1. Uses a custom `patchedFetch` that rewrites OIDC discovery responses to always show `https://` issuer
2. Keeps all HTTP calls internal (`http://`) so they reach Authelia on the Docker network
3. Disables the `authorization_response_iss_parameter_supported` check (which would otherwise reject the mismatched issuer)

This allows Nexterm to validate the OIDC flow correctly while keeping internal traffic on HTTP.

### 4. Authelia OIDC Client

The playbook integrates with `security/secure-homelab-access` — it:
1. Detects the Authelia setup via `~/.homelab-setup-vars.yml`
2. Generates an OIDC client secret (if missing)
3. Adds a `nexterm` OIDC client to Authelia's configuration with:
   - **Client ID:** `nexterm`
   - **Redirect URI:** `https://nexterm.yourdomain/api/auth/oidc/callback`
   - **Token endpoint auth:** `client_secret_post` (Nexterm's requirement)
   - **Scopes:** `openid`, `profile`, `email`

### 5. Caddy Reverse Proxy Entry

Adds a block to `/opt/homelab/caddy/Caddyfile`:

```
http://nexterm.yourdomain {
  import rate_limit
  import authelia
  reverse_proxy http://127.0.0.1:6989
}
```

This:
- Applies rate limiting (10 reqs/sec per IP)
- Enforces Authelia authentication
- Proxies traffic to the internal Nexterm container

### 6. DNS Integration

- **Cloudflare Tunnel:** adds DNS route `nexterm.yourdomain -> localhost`
- **Pi-hole:** adds local DNS record `nexterm.yourdomain -> 127.0.0.1`

### 7. Homepage Service Card

Adds Nexterm to the Homepage dashboard at `home.yourdomain`:

```yaml
- Nexterm:
    icon: terminal.png
    href: "https://nexterm.yourdomain"
    description: "Web-based terminal manager"
```

## Bootstrap Process (First Run Only)

On first run, the playbook's bootstrap block:

1. **Registers admin account** — Creates username `admin` with the configured password via `POST /api/accounts/register`
2. **Obtains session token** — Logs in to get an auth token for subsequent API calls
3. **Creates per-host SSH identities** — For each entry in `nexterm_connections`:
   - Calls `PUT /api/identities` with name `homelab-key-<hostname>`
   - Injects the SSH private key from `~/.ssh/id_ed25519`
   - Sets SSH username to the host-specific username (e.g., `kamil-rybacki` for `lw-main`)
4. **Creates SSH connections** — For each host, calls `PUT /api/entries` to create a server connection entry
5. **Writes sentinel file** — Creates `/opt/homelab/nexterm/.bootstrapped` to skip bootstrap on re-runs

## SSH Key Management

### The per-host identity approach

Instead of a single shared SSH key, each host gets its own named identity:

- **Identity name:** `homelab-key-<hostname>` (e.g., `homelab-key-lw-main`, `homelab-key-lw-s1`)
- **SSH key:** same private key (from `~/.ssh/id_ed25519`), but stored per-host
- **Username:** different SSH username per host (from `nexterm_connections[i].username`)

This allows:
- Different usernames on different target hosts (e.g., `kamil-rybacki` on lw-main, `kamil` on lw-s1)
- Future granularity: ability to use different keys for different hosts
- Clear visibility in the Nexterm UI of which identity is used for which host

### Adding the key to target hosts

Before running this playbook, ensure the SSH public key is on all target hosts:

```bash
# On control node
cat ~/.ssh/id_ed25519.pub
# Output: ssh-ed25519 AAAA... user@control-node

# On each target host (lw-main, lw-s1, etc.)
echo "ssh-ed25519 AAAA... user@control-node" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh
```

## Access via Browser

Once deployed:

1. Navigate to `https://nexterm.yourdomain`
2. You'll be redirected to `https://auth.yourdomain` for login (if not already authenticated)
3. Log in with your homelab credentials (Authelia 2FA)
4. Redirect back to Nexterm — you're logged in automatically via OIDC
5. Pre-configured connections appear in the left sidebar
6. Click any connection to open a web-based terminal

**Note:** The admin account (`admin`/`changeme`) is created on first run but is rarely used after that, since browser access goes through Authelia OIDC.

## Troubleshooting

### Nexterm container won't start

Check logs:

```bash
docker logs -f nexterm
```

Common issues:
- **Port 6989 already in use:** change `nexterm_port` in `group_vars/all.yml`
- **Encryption key file corrupted:** delete `/opt/homelab/nexterm/.encryption_key` and re-run (will generate a new one)

### Can't connect to target hosts

Check the following on each target host:

```bash
# Verify SSH public key is installed
grep "AAAA" ~/.ssh/authorized_keys

# Verify SSH is listening
ss -tlnp | grep :22

# Test SSH manually from control node
ssh -i ~/.ssh/id_ed25519 <target-username>@<target-ip>
```

If the manual SSH works but Nexterm fails:
- Check Nexterm logs: `docker logs -f nexterm`
- Verify the identity is created: access Nexterm UI → Settings → Identities
- Verify the connection is created: Nexterm UI → left sidebar should list all connections

### OIDC login loop

If you see a redirect loop between Nexterm and Authelia:

1. **Verify Authelia OIDC is enabled** — check `security/secure-homelab-access` logs
2. **Check the patched oidc.js is mounted** — verify in Nexterm container: `cat /app/server/controllers/oidc.js | head -20` should show the patched fetch logic
3. **Verify redirect URI matches** — in Authelia config, should be `https://nexterm.yourdomain/api/auth/oidc/callback`

### OIDC issuer mismatch error

If you see an error like `"issuer mismatch"` or `"iss parameter not supported"`:

This means the patched `oidc.js` is not being used or is not working correctly. The playbook copies it to `/opt/homelab/nexterm/patches/oidc.js` and mounts it at `/app/server/controllers/oidc.js`. Verify:

```bash
# On the control node
ls -la /opt/homelab/nexterm/patches/oidc.js

# Inside the container
docker exec nexterm ls -la /app/server/controllers/oidc.js
docker exec nexterm head -20 /app/server/controllers/oidc.js | grep patchedFetch
```

## Security Considerations

1. **Encryption key** — stored unencrypted at `/opt/homelab/nexterm/.encryption_key` (mode 0600). If compromised, all stored credentials in Nexterm's database are at risk.

2. **SSH private key** — the playbook reads `~/.ssh/id_ed25519` and injects it into Nexterm. If Nexterm is compromised, this key is exposed. Use a dedicated SSH key for Nexterm if you're concerned.

3. **Authelia OIDC** — requires `token_endpoint_auth_method: client_secret_post` because Nexterm doesn't support the default `client_secret_basic`. The client secret is stored in `security/secure-homelab-access` secrets (via Vault if available).

4. **Rate limiting** — Caddy applies 10 req/sec per IP to the Nexterm route (via `import rate_limit`).

5. **Container isolation** — Nexterm binds to `127.0.0.1:6989` only (not `0.0.0.0`), so it's not reachable directly from the internet — only through Caddy.

## Updating Nexterm

To update the Nexterm image:

1. Edit `group_vars/all.yml` — change `nexterm_image` version (or use `:latest`)
2. Re-run the playbook — it pulls the new image and restarts the container
3. The data directory (`/opt/homelab/nexterm/`) persists across updates

## Removing Nexterm

To clean up:

```bash
# Stop and remove the container
docker rm -f nexterm

# Remove the data directory (including encryption key!)
sudo rm -rf /opt/homelab/nexterm

# Remove from Caddy config
sudo nano /opt/homelab/caddy/Caddyfile  # Remove the nexterm block

# Remove from Authelia OIDC clients (edit config.yml)
sudo docker exec authelia ... # or re-run security/secure-homelab-access

# Reload Caddy
docker exec caddy caddy reload
```

## Related Playbooks

- **[security/secure-homelab-access](../../security/secure-homelab-access/)** — Deploys Authelia OIDC, Caddy, Pi-hole, and other prerequisites (run this first)
- **[dev-tools/claude-code-setup](../claude-code-setup/)** — Provisions Claude Code with MCP servers
- **[monitoring/librenms-setup](../../monitoring/librenms-setup/)** — Network monitoring (pairs well with Nexterm for infrastructure access)

## Version Info

- **Nexterm image:** `germannewsmaker/nexterm:latest`
- **Ansible:** >= 2.16
- **Docker:** >= 20.10

Last updated: 2026-03-22
