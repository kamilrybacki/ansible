---
name: docker-bind-mount-uid-permissions
description: "Bind-mounted files for non-root Docker containers must match container UID or cause silent crash loops"
user-invocable: false
origin: auto-extracted
---

# Docker Bind-Mount UID Permissions

**Extracted:** 2026-03-26
**Context:** Deploying Docker containers that run as non-root UIDs (CouchDB=5984, Elasticsearch=1000, Grafana=472, etc.)

## Problem

When bind-mounting config files or data directories into a Docker container that runs as a non-root user, the container crashes in a restart loop with **empty logs** if the host files are owned by root:root with restrictive permissions (e.g., 0600). Docker does not remap UIDs on bind mounts — the container process sees the host file ownership directly.

## Solution

Set ownership to the container's internal UID on all bind-mounted paths:

```yaml
# Ansible example for CouchDB (UID 5984)
- name: Create data directory
  ansible.builtin.file:
    path: /opt/service/data
    state: directory
    mode: "0700"
    owner: "5984"
    group: "5984"

- name: Template config file
  ansible.builtin.template:
    src: config.ini.j2
    dest: /opt/service/config.ini
    mode: "0644"       # NOT 0600 — container UID needs read access
    owner: "5984"
    group: "5984"
```

Common container UIDs:
- CouchDB: 5984
- Elasticsearch/OpenSearch: 1000
- Grafana: 472
- Redis: 999
- Prometheus: 65534 (nobody)

Find a container's UID: `docker inspect <image> --format '{{.Config.User}}'`

## When to Use

- Deploying any Docker container with bind-mounted volumes or config files
- Container is in a crash loop with empty or no logs
- `docker inspect` shows ExitCode 1 with no error message
