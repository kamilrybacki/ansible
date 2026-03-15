# Claude Code Setup

Ansible playbook for provisioning [Claude Code](https://claude.com/claude-code) with a full configuration: CLI installation, settings, rules, plugins, Serena MCP, standalone MCP servers, and custom commands.

## Prerequisites

- Ansible 2.10+
- SSH key-based access to the target (if provisioning a remote machine)
- `sudo` access on the target (for Node.js and system package installation)

## What Gets Installed

| Role | What it does |
|------|-------------|
| `claude_cli` | Installs Node.js 22 (via NodeSource) and Claude Code CLI (`npm install -g @anthropic-ai/claude-code`). Skips if already present. |
| `claude_config` | Copies `settings.json` and `rules/` into `~/.claude/`. Backs up existing settings. |
| `plugins` | Registers marketplaces (superpowers, everything-claude-code) and installs 5 plugins (superpowers, context7, github, serena, everything-claude-code). |
| `serena` | Installs `uv` via `pipx` and deploys Serena config to `~/.serena/` with dashboard auto-open disabled. |
| `mcp_servers` | Registers Gmail and Google Calendar MCP servers. |
| `commands` | Deploys `/serena-onboard` command for quick project registration with Serena. |

## Usage

### Provision this machine (localhost)

```bash
cd claude-code-setup
ansible-playbook -i inventory/hosts.ini setup.yml
```

Accept the default `localhost` when prompted.

### Provision a remote machine

```bash
cd claude-code-setup
ansible-playbook -i inventory/hosts.ini setup.yml
```

When prompted:
- **Target host:** enter the IP or hostname
- **SSH user:** enter the SSH username

## Post-Setup Steps

After the playbook completes:

1. **Authenticate Claude Code:** Run `claude login` on the target machine
2. **Complete OAuth flows:** Start Claude Code and trigger Gmail/Calendar MCP servers to complete OAuth
3. **Onboard projects to Serena:** In any project, run `/serena-onboard` inside Claude Code

## Customization

All defaults are in each role's `defaults/main.yml`. Override them in `group_vars/all.yml`:

```yaml
# Example: change Node.js version
node_major_version: 20

# Example: add more plugins
claude_plugins:
  - "superpowers@claude-plugins-official"
  - "my-plugin@my-marketplace"

# Example: add more MCP servers
claude_mcp_servers:
  - name: "my-server"
    transport: http
    url: "https://my-server.example.com/mcp"
    scope: user
```

## Configuration Files

The `files/` directory contains canonical configuration snapshots:

- `files/claude/settings.json` — Claude Code settings (plugins, marketplaces, MCP servers)
- `files/claude/rules/` — 44 rule files across 9 global + 7 language-specific categories
- `files/serena/serena_config.yml` — Serena MCP config (dashboard disabled, LSP backend)

To update these after changing your local config, re-copy the files:

```bash
cp ~/.claude/settings.json files/claude/settings.json
cp -r ~/.claude/rules files/claude/rules
cp ~/.serena/serena_config.yml files/serena/serena_config.yml
```
