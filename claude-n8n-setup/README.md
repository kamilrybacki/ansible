# claude-n8n-setup

Ansible playbook for setting up [n8n](https://n8n.io/) on a remote host via Docker and configuring [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to connect to it as an MCP server.

Designed for a home lab with two Linux machines on the same LAN.

## Prerequisites

- SSH key-based access from the control node to the n8n host
- Claude Code CLI installed on the client machine
- `community.docker` Ansible collection:
  ```bash
  ansible-galaxy collection install community.docker
  ```
- No firewall blocking port 5678 between machines

## Usage

```bash
ansible-playbook claude-n8n-setup/setup.yml \
  -i claude-n8n-setup/inventory/hosts.ini \
  --ask-become-pass
```

You will be prompted for:

| Prompt | Default | Description |
|---|---|---|
| n8n host IP | — | IP or hostname of the machine that will run n8n |
| n8n SSH user | — | SSH user on the n8n host |
| Claude Code client IP | `localhost` | IP of the Claude Code machine (use `localhost` if running from it) |
| Claude Code SSH user | — | SSH user on the Claude client (ignored if localhost) |
| Bearer token | *(auto-generated)* | Token for MCP auth; leave blank to generate a 48-char random token |
| MCP endpoint path | *(blank)* | e.g. `/mcp/<id>`; leave blank to configure later via n8n UI |

## Post-Setup

After the playbook completes:

1. Open `http://<n8n_host_ip>:5678` in a browser and complete the n8n initial setup.
2. Go to **Settings > MCP** and enable the MCP server.
3. Configure a **Header Auth** credential with header `Authorization` and value `Bearer <your-token>`.
4. If you left the MCP endpoint path blank during the playbook run, copy the path from n8n and either re-run the playbook or manually update `~/.claude.json`.
5. Verify with `claude mcp list`.

## Roles

| Role | What it does |
|---|---|
| `docker` | Installs Docker engine via the official APT repository (Debian/Ubuntu) |
| `n8n` | Creates a Docker volume and runs the n8n container with persistence |
| `claude_mcp` | Registers n8n as an MCP server in Claude Code at user scope |

## Structure

```
claude-n8n-setup/
├── setup.yml
├── inventory/
│   └── hosts.ini
├── group_vars/
│   └── all.yml          <- shared vars (container name, port, image, etc.)
└── roles/
    ├── docker/
    ├── n8n/
    └── claude_mcp/
```
