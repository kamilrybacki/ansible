<h1 align="center">Ansible Homelab</h1>

<p align="center">
  <strong>Infrastructure as Code for rapidly provisioning Linux environments, homelab services, and Kubernetes clusters.</strong>
</p>

<p align="center">
  <a href="https://github.com/kamilrybacki/ansible/actions/workflows/ci-fast.yml"><img src="https://github.com/kamilrybacki/ansible/actions/workflows/ci-fast.yml/badge.svg?branch=main" alt="CI - Fast"></a>
  <a href="https://github.com/kamilrybacki/ansible/actions/workflows/ci-heavy.yml"><img src="https://github.com/kamilrybacki/ansible/actions/workflows/ci-heavy.yml/badge.svg?branch=main" alt="CI - Heavy"></a>
  <img src="https://img.shields.io/badge/ansible-%3E%3D2.16-EE0000?logo=ansible&logoColor=white" alt="Ansible">
  <img src="https://img.shields.io/badge/molecule-tested-2ECC40?logo=testing-library&logoColor=white" alt="Molecule Tested">
  <img src="https://img.shields.io/badge/roles-80-blue" alt="Roles">
  <img src="https://img.shields.io/badge/playbooks-27-blue" alt="Playbooks">
</p>

---

## Overview

A collection of **27 self-contained Ansible playbook sets** organized into 8 functional categories. Each playbook is fully independent with its own inventory, roles, and variables — no global shared state.

**Key features:**

- Interactive setup wizards via `vars_prompt` — no manual file editing required
- Docker-first deployments with pinned image versions and localhost-only bindings
- Optional HashiCorp Vault integration — secrets auto-loaded/stored when Vault is available
- Tiered CI/CD pipeline with Molecule + Testinfra covering 81% of roles
- Security by default: `no_log` on secrets, UFW firewall, fail2ban, Authelia 2FA

> **Full documentation:** See the [docs site](https://kamilrybacki.github.io/ansible/) for detailed service info — Docker images, ports, Vault paths, and configuration for every service.

---

## Playbooks

| Category | Playbooks |
|----------|-----------|
| **Security** | [`secure-homelab-access`](./security/secure-homelab-access/) (WireGuard, Authelia 2FA, Caddy, Pi-hole, CrowdSec, fail2ban, UFW), [`vault-setup`](./security/vault-setup/) (HashiCorp Vault), [`vaultwarden-setup`](./security/vaultwarden-setup/) (Bitwarden), [`lab-network`](./security/lab-network/) (gateway) |
| **AI** | [`openclaw-setup`](./ai/openclaw-setup/) (multi-provider AI agents + Ollama), [`dify-setup`](./ai/dify-setup/) (LLM platform + LiteLLM), [`swe-af-setup`](./ai/swe-af-setup/) (autonomous SWE agent) |
| **Automation** | [`n8n-setup`](./automation/n8n-setup/) (workflow automation), [`claude-n8n-mcp`](./automation/claude-n8n-mcp/) (Claude Code MCP bridge) |
| **Monitoring** | [`librenms-setup`](./monitoring/librenms-setup/) (network monitoring), [`netbox-setup`](./monitoring/netbox-setup/) (IPAM/DCIM), [`kuma-setup`](./monitoring/kuma-setup/) (uptime monitoring), [`homeassistant-setup`](./monitoring/homeassistant-setup/) (home automation), [`bambulab-setup`](./monitoring/bambulab-setup/) (3D printer) |
| **Files** | [`paperless-setup`](./files/paperless-setup/) (document OCR), [`stirling-pdf-setup`](./files/stirling-pdf-setup/) (PDF toolkit), [`seafile-setup`](./files/seafile-setup/) (file sync), [`nas-setup`](./files/nas-setup/) (mergerfs + SnapRAID) |
| **Desktop** | [`i3-setup`](./desktop/i3-setup/) (i3wm), [`handy-setup`](./desktop/handy-setup/) (speech-to-text), [`audiorelay-setup`](./desktop/audiorelay-setup/) (USB mic), [`weylus-setup`](./desktop/weylus-setup/) (drawing tablet) |
| **Dev Tools** | [`claude-code-setup`](./dev-tools/claude-code-setup/) (Claude Code CLI, plugins, MCP servers, Serena) |
| **Kubernetes** | [`kind-setup`](./k8s/kind-setup/), [`k8s-full-setup`](./k8s/k8s-full-setup/), [`proxmox-k8s-setup`](./k8s/proxmox-k8s-setup/), [`helm-setup`](./k8s/helm-setup/), [`k9s-setup`](./k8s/k9s-setup/), [`headlamp-setup`](./k8s/headlamp-setup/), [`argocd-setup`](./k8s/argocd-setup/) |

---

## Quick Start

```bash
# Clone and install dependencies
git clone https://github.com/kamilrybacki/ansible.git && cd ansible
ansible-galaxy collection install -r requirements.yml

# Run any playbook (interactive wizard guides you through config)
ansible-playbook monitoring/kuma-setup/setup.yml \
  -i monitoring/kuma-setup/inventory/hosts.ini \
  --ask-become-pass
```

### Recommended First-Run Order

```
# Fresh homelab server                    # Dev machine
1. security/secure-homelab-access         1. desktop/i3-setup
2. security/vault-setup (optional)        2. dev-tools/claude-code-setup
3. monitoring/librenms-setup              3. k8s/k8s-full-setup
4. ai/*, automation/*, files/*
```

### Vault Integration (Optional)

When `security/vault-setup` is deployed, all other playbooks automatically detect Vault via `~/.vault-ansible.yml`, pre-fill prompt defaults from `secret/homelab/<service>`, and store secrets back after deployment.

---

## Testing

Every role is tested with [Molecule](https://ansible.readthedocs.io/projects/molecule/) + [Testinfra](https://testinfra.readthedocs.io/) across a tiered CI pipeline.

| Tier | Trigger | Driver | Roles |
|------|---------|--------|-------|
| **Fast** | Every push to `main`, all PRs | Docker | 56 |
| **Heavy** | Nightly, PRs touching `security/`, `monitoring/`, or `files/` | Privileged Docker / QEMU | 9 |

```
65 / 80 roles tested (81%)
15 excluded: need block devices, running k8s, Proxmox API, or hardware
```

```bash
# Run tests locally
pip install -r requirements-test.txt
make lint                                              # yamllint + ansible-lint
make test-role ROLE_PATH=monitoring/kuma-setup/roles/kuma  # single role
make test-all-docker                                   # all Docker roles
```

Adding a `molecule/` directory to any role automatically enrolls it in CI — no workflow edits needed.

---

## Project Structure

```
ansible/
├── .github/workflows/       # CI/CD pipelines (fast + heavy tiers)
├── common/                   # Shared Vault integration + prerequisites role
├── docs/                     # GitHub Pages documentation site
├── scripts/                  # Discovery and test runner scripts
│
├── security/                 # Access control & secrets management
├── ai/                       # AI & LLM platforms
├── automation/               # Workflow automation
├── monitoring/               # Observability & home automation
├── files/                    # Documents & file storage
├── desktop/                  # Desktop environment & utilities
├── dev-tools/                # Developer tooling
└── k8s/                      # Kubernetes cluster provisioning
```

---

## Security Notes

- All containers bind to `127.0.0.1` by default
- All secrets use `no_log: true`
- Container images pinned to specific versions
- UFW firewall, fail2ban, Authelia 2FA
- CI workflows scoped to `permissions: contents: read`

---

## License

Private repository. All rights reserved.
