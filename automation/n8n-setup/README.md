# n8n Setup

Deploys [n8n](https://n8n.io) workflow automation via Docker. Integrates with the homelab stack (Caddy reverse proxy, Cloudflare Tunnel, Pi-hole DNS, Homepage dashboard).

## Usage

```bash
ansible-playbook automation/n8n-setup/setup.yml \
  -i automation/n8n-setup/inventory/hosts.ini \
  --ask-become-pass
```

The wizard prompts for the target host IP, SSH user, and n8n owner account details.

## Vault Secrets

Vault path: **`secret/homelab/n8n`**

Store the owner password before running (Vault must be unsealed and `~/.vault-ansible.yml` present):

```bash
vault kv put secret/homelab/n8n \
  owner_password=<n8n-owner-password> \
  workflows_repo_token=<github-pat>   # only if workflows repo is private
```

Service secrets (API tokens, etc.) live at the same path:

```bash
# Add or update any secret — n8n picks it up within 5 minutes, no restart needed
vault kv patch secret/homelab/n8n netbox_token=<value>
vault kv patch secret/homelab/n8n librenms_token=<value>
vault kv patch secret/homelab/n8n my_new_key=<value>
```

## Vault → n8n Variable Sync (`vault-n8n-sync` sidecar)

n8n's External Secrets and Variables APIs are both enterprise-only in 2.x.
The `N8N_VAR_*` environment variable mechanism IS community edition — any env var
prefixed `N8N_VAR_` is readable in workflows via `$env.N8N_VAR_KEY_NAME`.

The `n8n-vault-shim` sidecar container automates this:

1. Polls `secret/homelab/n8n` in Vault every 300 s (configurable)
2. Compares the secrets with the current `N8N_VAR_*` env vars on the n8n container
3. If anything changed, checks whether any workflow executions are active — if yes, **skips and retries next cycle** to avoid interrupting running jobs
4. Otherwise gracefully recreates the n8n container with the updated env vars (~30 s downtime)

Reference secrets in workflow nodes (Set node expressions or Code nodes):

```
={{ $env.N8N_VAR_netbox_token }}
={{ $env.N8N_VAR_librenms_token }}
={{ $env.N8N_VAR_my_new_key }}
```

In Code nodes use `process.env.N8N_VAR_KEY_NAME` instead of `$env.*`.

To add a new secret and have it available in n8n within one poll interval:

```bash
vault kv patch secret/homelab/n8n my_new_key=<value>
```

Poll interval is 300 seconds by default, configurable via `n8n_external_secrets_update_interval` in `group_vars/all.yml`.

**Never hardcode tokens in workflow JSON files.** Workflow files are stored in a Git repository.

## Workflow Repository

Workflows are sourced from [kamilrybacki/n8n-workflows](https://github.com/kamilrybacki/n8n-workflows) at deploy time. The Ansible role clones the repo and imports all `*.json` files via the n8n CLI. The repo is private — a GitHub PAT stored at `workflows_repo_token` in Vault is required.

For ongoing backup, configure **Settings > Source Control** in the n8n UI after deployment:
1. Connect to the workflows repository
2. Generate an SSH key pair in n8n
3. Add the public key as a deploy key (write access) to the GitHub repo

## Post-Deployment

After the playbook completes:

1. Log in to n8n and configure Source Control (see above)
2. Go to **Settings > Instance-level MCP** and copy your MCP Access Token
3. Run the Claude Code MCP integration:

```bash
ansible-playbook dev-tools/claude-n8n-mcp/setup.yml \
  -i dev-tools/claude-n8n-mcp/inventory/hosts.ini
```
