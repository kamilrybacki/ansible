# lw-c1 Compute Node Setup — Design Spec

**Date:** 2026-03-26
**Status:** Draft

---

## Overview

Set up `lw-c1` (192.168.0.107, Lenovo M900 Tiny, i7-6700T, 16GB RAM, 256GB NVMe, xUbuntu) as the dedicated compute node for the homelab. The node will run a K3s Kubernetes cluster hosting n8n queue-mode workers, GitHub Actions runners, and a vCluster-based test environment.

All other nodes (lw-main, lw-s1, lw-nas) change minimally. OpenClaw stays on lw-main.

---

## Goals

- Move all compute execution workloads (n8n workflow workers, GitHub Actions runners) off lw-s1 and onto lw-c1
- Provide a lightweight ephemeral test K8s environment for integration/e2e tests
- Keep operational complexity low — single-node K3s, no Proxmox, no VMs
- Integrate with existing infrastructure: Vault for secrets, lw-nas Redis/Postgres for n8n state and queue

---

## Architecture

### Node Map (post-setup)

| Node | IP | Role | Changes |
|------|----|------|---------|
| lw-c1 | 192.168.0.107 | Compute: K3s cluster | NEW |
| lw-s1 | 192.168.0.108 | n8n main (queue mode) | Queue mode enabled, runner removed |
| lw-main | 192.168.0.105 | Core infra, security, AI | UFW allow lw-c1 → NAS; otherwise unchanged |
| lw-nas | 10.0.1.2 | Storage, shared DBs | Add lw-c1 to DB allowed clients |

### lw-c1 K3s Cluster Workloads

| Workload | Kind | Replicas | Notes |
|----------|------|----------|-------|
| n8n-workers | Deployment | 2 | Queue mode workers, connects to Redis + Postgres on lw-nas |
| github-runner | Deployment | 2 | `myoung34/github-runner`, same repo as current lw-s1 runner |
| vCluster | Helm release | 1 | `test` namespace, ephemeral test K8s environment |
| Headlamp | Helm release | 1 | Web dashboard, exposed as NodePort on lw-c1 |
| ArgoCD | Helm release | 1 | GitOps controller, accessed via `kubectl port-forward` or NodePort |

---

## K8s Distribution: K3s

K3s is chosen over kind and kubeadm for the following reasons:

- **Lowest overhead** — ~500MB for K3s itself, leaving ~14GB for workloads
- **Systemd-managed** — survives reboots without additional configuration
- **Single binary** — simple to install, upgrade, and maintain via Ansible
- **vCluster compatible** — vCluster supports K3s as an underlying cluster
- **No VMs required** — runs directly on bare-metal Ubuntu, no Proxmox overhead

kind was ruled out because it doesn't persist across reboots by default and is designed for ephemeral local dev clusters, not persistent workload hosting. kubeadm was ruled out as overkill for a single-node cluster.

### K3s Defaults Used

- CNI: Flannel (default) — pod traffic is masqueraded behind the node IP `192.168.0.107` before leaving the host. This means lw-nas firewall rules keyed on `192.168.0.107` correctly match pod-originated traffic.
- Pod CIDR: `10.244.0.0/16` — no conflict with LAN (192.168.0.0/24), NAS link (10.0.1.0/24), VPN (10.8.0.0/24), or service CIDR (10.96.0.0/12)

---

## Ansible Bootstrap for lw-c1

Before any playbook runs, lw-c1 must be reachable via SSH from the Ansible control node (lw-main or local machine). Required pre-steps:

1. SSH key from control node deployed to `kamil@lw-c1` (same user as lw-s1)
2. lw-c1 added to the global inventory with `sudo HOME=/home/kamil-rybacki` (matching the established pattern for all homelab nodes)
3. Python 3 available on lw-c1 (`ansible_python_interpreter=/usr/bin/python3`)

Example inventory entry (added to the relevant `hosts.ini` files):
```ini
[compute]
lw-c1 ansible_host=192.168.0.107 ansible_user=kamil ansible_python_interpreter=/usr/bin/python3
```

Vault access: Ansible runs on the control node (lw-main/localhost) where Vault is locally reachable at `http://127.0.0.1:8200`. The `k8s-setup` playbooks read secrets from Vault locally and push them as K8s Secrets to lw-c1 via the kubeconfig. No runtime Vault access from pods is needed.

---

## Kubeconfig Access

After K3s installs on lw-c1, the admin kubeconfig is at `/etc/rancher/k3s/k3s.yaml` on lw-c1 (server address `127.0.0.1:6443`). The `k3s-setup` playbook will:

1. Fetch the kubeconfig from lw-c1 via Ansible `fetch`
2. Rewrite the server address to `https://192.168.0.107:6443`
3. Save it locally to `~/.kube/lw-c1.yaml` on the control node
4. Subsequent playbooks (`n8n-workers-setup`, `github-runners-setup`, `vcluster-setup`) set `KUBECONFIG=~/.kube/lw-c1.yaml` and apply manifests using `kubectl` or the `kubernetes.core` Ansible collection from the control node

The kubeconfig contains cluster admin credentials — it must not be committed to git.

---

## n8n Queue Mode

### Current state
n8n on lw-s1 runs in the default single-process mode. All workflow executions happen in the main process.

### Target state
- **lw-s1**: n8n main instance — handles UI, webhooks, and API. No workflow execution.
- **lw-c1 K3s**: n8n worker Deployment (2 replicas) — polls Redis queue, executes workflows, writes results to Postgres.

### Required env vars on lw-s1 n8n main

```
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=10.0.1.2
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0
```

If Redis requires a password, `QUEUE_BULL_REDIS_PASSWORD` must also be set. These vars must be added to the `n8n-vault-shim` preserved env list on lw-s1 so they survive container recreation. The `automation/n8n-setup/` playbook update includes updating the shim's env var manifest.

### Postgres password sync

The `feedback_shared_db_password_sync.md` pattern applies: shared-postgres on lw-nas generates init passwords independently. Before n8n workers can connect, verify n8n's Postgres password in Vault matches the actual DB password. If not, run `ALTER USER` on lw-nas to sync them. This is a pre-deployment verification step in `n8n-workers-setup`.

### Worker image version

n8n workers must run the same image tag as the main instance on lw-s1. The `k8s/n8n-workers-setup/group_vars/all.yml` will read `n8n_version` from a shared var, keeping both in sync. The worker Deployment image: `docker.n8n.io/n8nio/n8n:{{ n8n_version }}`.

### Queue flow
```
lw-s1: n8n main (EXECUTIONS_MODE=queue)
  → enqueues job → Redis (10.0.1.2:6379)
  → reads/writes state → Postgres (10.0.1.2:5432)

lw-c1 K3s: n8n-workers Deployment (x2)
  → polls Redis queue
  → executes workflow
  → writes result → Postgres (10.0.1.2:5432)
```

### Secrets for workers

Workers get credentials via K8s Secrets, written at deploy time by the Ansible `n8n-workers-setup` playbook reading from Vault. Because workers use static K8s Secrets (no shim), re-running `n8n-workers-setup` is required after Vault secret rotations to keep worker credentials current. This is noted in the runbook.

### `claude-backup-redis` on lw-s1

The `claude-backup-redis` container (port 6380) is unrelated to n8n queue mode — it is a separate Redis instance used for Claude session backup. No changes needed.

---

## GitHub Actions Runners

The `myoung34/github-runner` Deployment (2 replicas) runs on lw-c1, targeting `kamilandrzejrybacki-inc/n8n-workflows`.

**Registration:** The `myoung34/github-runner` image supports registration via a long-lived GitHub PAT (`GITHUB_TOKEN` env var) or GitHub App credentials, not the ephemeral one-time registration token. A PAT with `repo` scope is stored in Vault and injected as a K8s Secret at deploy time. The image handles automatic re-registration on pod restart.

**Removal ordering:** The lw-s1 runner is removed only after the lw-c1 runners are confirmed registered and actively picking up jobs (verified by checking the GitHub Actions runner list in the repo settings). This avoids a CI availability gap.

**Future path:** Actions Runner Controller (ARC) for per-job pod isolation, if required.

---

## vCluster (Test Environment)

A vCluster Helm release is deployed into the `test` namespace of the K3s cluster. It provides a fully isolated K8s API surface (own namespaces, RBAC, CRDs) for integration and e2e tests.

- ~200–400MB RAM overhead
- Lifecycle: ArgoCD manages the vCluster Helm release for persistent existence. For ephemeral per-suite teardown, a separate `vcluster-teardown` Ansible task (or ArgoCD Application `syncPolicy: manual`) is used. The primary model is: vCluster is always running; test suites use it and clean up their own namespaces within it.

---

## Networking

K3s runs directly on the lw-c1 host interface (`192.168.0.107`). Pod traffic exits the node masqueraded behind the host IP via K3s Flannel SNAT — firewall rules on lw-main and lw-nas keyed on `192.168.0.107` correctly match pod-originated connections.

**NAS subnet route on lw-c1:** lw-c1 needs a route to `10.0.1.0/24` via lw-main (`192.168.0.105`) to reach lw-nas. This mirrors the route already added for lw-s1 by `nas-link-setup`. A new play targeting lw-c1 will be added to `nas-link-setup/setup.yml`.

**CIDR conflict check:**

| Network | CIDR | Conflict? |
|---------|------|-----------|
| LAN | 192.168.0.0/24 | — |
| NAS link | 10.0.1.0/24 | — |
| WireGuard VPN | 10.8.0.0/24 | — |
| K3s pod CIDR | 10.244.0.0/16 | None |
| K3s service CIDR | 10.96.0.0/12 | None |

---

## Headlamp and ArgoCD Access

- **Headlamp**: exposed as a NodePort on lw-c1. Accessible at `http://192.168.0.107:<nodeport>` from LAN. A Caddy reverse proxy entry on lw-main (`headlamp-c1.*`) can be added later if external access is needed.
- **ArgoCD**: accessible via `kubectl port-forward -n argocd svc/argocd-server 8443:443` from a machine with the lw-c1 kubeconfig. NodePort or Caddy ingress deferred to post-setup.

---

## Ansible Playbook Changes

### New playbooks

| Playbook | Target | Purpose |
|----------|--------|---------|
| `k8s/k3s-setup/` | lw-c1 | Install K3s, fetch kubeconfig, deploy Helm/k9s/Headlamp/ArgoCD |
| `k8s/n8n-workers-setup/` | lw-c1 K3s | K8s Deployment + Secret for n8n queue workers |
| `k8s/github-runners-setup/` | lw-c1 K3s | K8s Deployment + Secret for GitHub Actions runners |
| `k8s/vcluster-setup/` | lw-c1 K3s | Helm vCluster in `test` namespace |

### Updated playbooks

| Playbook | Change |
|----------|--------|
| `automation/n8n-setup/` | Add queue mode env vars to n8n on lw-s1; update shim preserved env list; remove github-runner container |
| `infrastructure/nas-link-setup/` | Add NAS subnet route for lw-c1; add 192.168.0.107 to NAS DB allowed clients and UFW forward rules |

### Reused roles (applied to lw-c1 as part of `k3s-setup`)
- `helm` — from `k8s/helm-setup/`
- `k9s` — from `k8s/k9s-setup/`
- `headlamp` — from `k8s/headlamp-setup/`
- `argocd` — from `k8s/argocd-setup/`

---

## Rollback Plan

If the lw-s1 → queue mode transition fails:

1. Stop n8n-workers Deployment on lw-c1 (`kubectl scale deploy/n8n-workers --replicas=0`)
2. Remove queue mode env vars from n8n on lw-s1 (`EXECUTIONS_MODE` unset, Redis vars removed)
3. Restart n8n on lw-s1 — it returns to single-process mode automatically
4. Revert `automation/n8n-setup/` changes and re-run playbook
5. Re-register lw-s1 GitHub runner if it was removed before lw-c1 runners were verified

---

## Out of Scope

- Proxmox installation (decided against — unnecessary overhead for single-node use case)
- Actions Runner Controller (ARC) — deferred, simple Deployment sufficient for now
- Moving n8n main instance off lw-s1
- Any changes to lw-main services beyond UFW forward rule
- Caddy ingress for Headlamp/ArgoCD (deferred to post-setup)
