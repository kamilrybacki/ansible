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

## Vault External Secrets Integration

At deploy time the playbook automatically:

1. Creates a read-only Vault policy `n8n-secrets-reader` scoped to `secret/data/homelab/n8n`
2. Generates a scoped reader token and configures n8n's native External Secrets integration against `http://<vault-host>:8200`
3. Secrets are available in all workflow nodes immediately after the first poll

Reference secrets in workflow nodes:

```
={{ $secrets.vault.netbox_token }}
={{ $secrets.vault.librenms_token }}
={{ $secrets.vault.my_new_key }}
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
