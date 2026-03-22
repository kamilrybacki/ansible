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

Store secrets before running (Vault must be unsealed):

```bash
vault kv put secret/n8n \
  owner_password=<n8n-owner-password> \
  netbox_token=<netbox-api-token> \
  librenms_token=<librenms-api-token> \
  workflows_repo_token=<github-pat>   # only if workflows repo is private
```

| Key | Purpose |
|-----|---------|
| `owner_password` | n8n owner account password |
| `netbox_token` | Injected as `$vars.NETBOX_TOKEN` in workflows |
| `librenms_token` | Injected as `$vars.LIBRENMS_TOKEN` in workflows |
| `workflows_repo_token` | GitHub PAT for cloning a private workflows repo |

## Workflow Credentials

Service API tokens are injected into the n8n container as `N8N_VAR_*` environment variables and accessed in workflow nodes via:

```
={{ $vars.NETBOX_TOKEN }}
={{ $vars.LIBRENMS_TOKEN }}
```

**Never hardcode tokens in workflow JSON files.** Workflow files are stored in a Git repository and must not contain secrets.

## Workflow Repository

Workflows are sourced from [kamilrybacki/n8n-workflows](https://github.com/kamilrybacki/n8n-workflows) at deploy time. The Ansible role clones the repo and imports all `*.json` files via the n8n CLI.

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
