# Knowledge Vault Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Syncthing + Quartz on the shared database host to provide a private, Authelia-protected web viewer for an Obsidian vault at `kb.<domain>`.

**Architecture:** Syncthing container receives vault files from a Linux desktop via P2P sync into a shared Docker volume. Quartz container watches that volume and auto-rebuilds a static site served on port 8080. Caddy proxies `kb.<domain>` behind Authelia.

**Tech Stack:** Ansible, Docker Compose, Syncthing, Quartz (Node.js static site generator), Caddy, HashiCorp Vault

**Spec:** `docs/superpowers/specs/2026-03-26-knowledge-vault-viewer-design.md`

---

### Task 1: Scaffold Directory Structure

**Files:**
- Create: `files/knowledge-vault-setup/inventory/hosts.ini`
- Create: `files/knowledge-vault-setup/group_vars/all.yml`
- Create: `files/knowledge-vault-setup/roles/syncthing/defaults/main.yml`
- Create: `files/knowledge-vault-setup/roles/syncthing/tasks/main.yml` (placeholder)
- Create: `files/knowledge-vault-setup/roles/syncthing/handlers/main.yml` (placeholder)
- Create: `files/knowledge-vault-setup/roles/syncthing/templates/` (empty)
- Create: `files/knowledge-vault-setup/roles/quartz/defaults/main.yml`
- Create: `files/knowledge-vault-setup/roles/quartz/tasks/main.yml` (placeholder)
- Create: `files/knowledge-vault-setup/roles/quartz/templates/` (empty)
- Create: `files/knowledge-vault-setup/roles/docker/defaults/main.yml`
- Create: `files/knowledge-vault-setup/roles/docker/tasks/main.yml`

- [ ] **Step 1: Create directories**

```bash
cd /home/kamil-rybacki/Code/ansible
mkdir -p files/knowledge-vault-setup/{inventory,group_vars}
mkdir -p files/knowledge-vault-setup/roles/syncthing/{defaults,tasks,handlers,templates}
mkdir -p files/knowledge-vault-setup/roles/syncthing/molecule/default/{tests,vars}
mkdir -p files/knowledge-vault-setup/roles/quartz/{defaults,tasks,templates}
mkdir -p files/knowledge-vault-setup/roles/quartz/molecule/default/{tests,vars}
mkdir -p files/knowledge-vault-setup/roles/docker/{defaults,tasks}
```

- [ ] **Step 2: Create inventory/hosts.ini**

Create `files/knowledge-vault-setup/inventory/hosts.ini`:
```ini
[vault_hosts]
```

- [ ] **Step 3: Create group_vars/all.yml**

Create `files/knowledge-vault-setup/group_vars/all.yml`:
```yaml
---
# Syncthing
syncthing_container_name: syncthing
syncthing_image: "syncthing/syncthing:1.29"
syncthing_sync_port: 22000
syncthing_ui_port: 8384
syncthing_data_dir: /opt/knowledge-vault/syncthing
syncthing_restart_policy: unless-stopped
syncthing_health_check_retries: 20
syncthing_health_check_delay: 10
syncthing_puid: "1000"
syncthing_pgid: "1000"

# Quartz
quartz_container_name: quartz
quartz_port: 8080
quartz_data_dir: /opt/knowledge-vault/quartz
quartz_restart_policy: unless-stopped
quartz_health_check_retries: 30
quartz_health_check_delay: 10
quartz_page_title: "Knowledge Vault"

# Shared
vault_content_dir: /opt/knowledge-vault/content
vault_hostname: "kb"
docker_network_name: vault-net
```

- [ ] **Step 4: Create Docker role (reuse from obsidian-livesync)**

Create `files/knowledge-vault-setup/roles/docker/defaults/main.yml`:
```yaml
---
docker_packages:
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-compose-plugin
```

Create `files/knowledge-vault-setup/roles/docker/tasks/main.yml`:
```yaml
---
- name: Check if Docker is already installed
  ansible.builtin.command: docker --version
  register: docker_check
  changed_when: false
  failed_when: false

- name: Install prerequisites for APT over HTTPS
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
      - gnupg
    state: present
    update_cache: true
  when: docker_check.rc != 0

- name: Create keyrings directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"
  when: docker_check.rc != 0

- name: Download Docker GPG key
  ansible.builtin.get_url:
    url: "https://download.docker.com/linux/{{ ansible_distribution | lower }}/gpg"
    dest: /etc/apt/keyrings/docker.asc
    mode: "0644"
  when: docker_check.rc != 0

- name: Add Docker APT repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [arch={{ arch_map[ansible_architecture] | default(ansible_architecture) }}
      signed-by=/etc/apt/keyrings/docker.asc]
      https://download.docker.com/linux/{{ ansible_distribution | lower }}
      {{ ansible_distribution_release }} stable
    filename: docker
    state: present
  vars:
    arch_map:
      x86_64: amd64
      aarch64: arm64
  when: docker_check.rc != 0

- name: Install Docker packages
  ansible.builtin.apt:
    name: "{{ docker_packages }}"
    state: present
    update_cache: true
  when: docker_check.rc != 0

- name: Ensure Docker service is running and enabled
  ansible.builtin.systemd:
    name: docker
    state: started
    enabled: true

- name: Add SSH user to docker group
  ansible.builtin.user:
    name: "{{ ansible_user }}"
    groups: docker
    append: true
```

- [ ] **Step 5: Create placeholder files for syncthing and quartz roles**

Create `files/knowledge-vault-setup/roles/syncthing/defaults/main.yml`:
```yaml
---
# Defaults are in group_vars/all.yml
```

Create `files/knowledge-vault-setup/roles/syncthing/tasks/main.yml`:
```yaml
---
# Populated in Task 2
```

Create `files/knowledge-vault-setup/roles/syncthing/handlers/main.yml`:
```yaml
---
# Populated in Task 2
```

Create `files/knowledge-vault-setup/roles/quartz/defaults/main.yml`:
```yaml
---
# Defaults are in group_vars/all.yml
```

Create `files/knowledge-vault-setup/roles/quartz/tasks/main.yml`:
```yaml
---
# Populated in Task 3
```

- [ ] **Step 6: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/
git commit -m "feat: scaffold knowledge-vault-setup playbook directory structure"
```

---

### Task 2: Syncthing Role — Templates, Tasks, Handlers

**Files:**
- Create: `files/knowledge-vault-setup/roles/syncthing/templates/docker-compose.yml.j2`
- Modify: `files/knowledge-vault-setup/roles/syncthing/tasks/main.yml`
- Modify: `files/knowledge-vault-setup/roles/syncthing/handlers/main.yml`
- Create: `files/knowledge-vault-setup/roles/syncthing/molecule/default/tests/test_default.py`

- [ ] **Step 1: Create Molecule test**

Create `files/knowledge-vault-setup/roles/syncthing/molecule/default/tests/test_default.py`:
```python
"""Testinfra tests for syncthing role."""


def test_syncthing_data_directory_exists(host):
    """Verify the Syncthing data directory was created."""
    assert host.file("/opt/knowledge-vault/syncthing").is_directory


def test_syncthing_content_directory_exists(host):
    """Verify the shared vault content directory was created."""
    assert host.file("/opt/knowledge-vault/content").is_directory


def test_syncthing_compose_file_exists(host):
    """Verify the Docker Compose file was templated."""
    compose = host.file("/opt/knowledge-vault/syncthing/docker-compose.yml")
    assert compose.exists
    assert compose.mode == 0o600


def test_syncthing_container_running(host):
    """Verify the Syncthing container is running."""
    result = host.run("docker ps --filter name=syncthing --format '{{.Status}}'")
    assert "Up" in result.stdout


def test_syncthing_sync_port_listening(host):
    """Verify Syncthing sync protocol is listening."""
    socket = host.socket("tcp://0.0.0.0:22000")
    assert socket.is_listening


def test_syncthing_ui_port_listening(host):
    """Verify Syncthing Web UI is listening on localhost."""
    socket = host.socket("tcp://127.0.0.1:8384")
    assert socket.is_listening


def test_syncthing_api_responds(host):
    """Verify Syncthing API is accessible."""
    result = host.run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8384/rest/system/status")
    assert result.stdout.strip() in ["200", "401", "403"]
```

- [ ] **Step 2: Create docker-compose.yml.j2**

Create `files/knowledge-vault-setup/roles/syncthing/templates/docker-compose.yml.j2`:
```yaml
services:
  syncthing:
    container_name: {{ syncthing_container_name }}
    image: {{ syncthing_image }}
    restart: {{ syncthing_restart_policy }}
    environment:
      PUID: "{{ syncthing_puid }}"
      PGID: "{{ syncthing_pgid }}"
    ports:
      - "{{ syncthing_sync_port }}:22000/tcp"
      - "{{ syncthing_sync_port }}:22000/udp"
      - "127.0.0.1:{{ syncthing_ui_port }}:8384"
    volumes:
      - {{ syncthing_data_dir }}/config:/var/syncthing/config
      - {{ vault_content_dir }}:/var/syncthing/vault
    networks:
      - {{ docker_network_name }}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8384/rest/noauth/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

networks:
  {{ docker_network_name }}:
    driver: bridge
```

- [ ] **Step 3: Write syncthing tasks/main.yml**

Replace `files/knowledge-vault-setup/roles/syncthing/tasks/main.yml` with:
```yaml
---
- name: Install Python Docker SDK
  ansible.builtin.apt:
    name:
      - python3-docker
      - curl
    state: present

- name: Create Syncthing directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    mode: "{{ item.mode }}"
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
  loop:
    - { path: "{{ syncthing_data_dir }}", mode: "0755", owner: root, group: root }
    - { path: "{{ syncthing_data_dir }}/config", mode: "0700", owner: "{{ syncthing_puid }}", group: "{{ syncthing_pgid }}" }
    - { path: "{{ vault_content_dir }}", mode: "0755", owner: "{{ syncthing_puid }}", group: "{{ syncthing_pgid }}" }

- name: Ensure local secrets directory exists
  ansible.builtin.file:
    path: "{{ lookup('env', 'HOME') }}/.homelab-secrets/knowledge-vault"
    state: directory
    mode: "0700"
  delegate_to: localhost
  become: false

- name: Generate and persist Syncthing admin password (idempotent)
  ansible.builtin.set_fact:
    syncthing_admin_password: "{{ syncthing_admin_password | default(lookup('password', lookup('env', 'HOME') + '/.homelab-secrets/knowledge-vault/syncthing_admin_password chars=ascii_letters,digits length=32')) }}"
  no_log: true

- name: Restrict local secret file to owner-only
  ansible.builtin.file:
    path: "{{ lookup('env', 'HOME') }}/.homelab-secrets/knowledge-vault/syncthing_admin_password"
    mode: "0600"
  delegate_to: localhost
  become: false

- name: Ensure vault-net Docker network exists
  community.docker.docker_network:
    name: "{{ docker_network_name }}"
    state: present

- name: Template Docker Compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ syncthing_data_dir }}/docker-compose.yml"
    mode: "0600"
    owner: root
    group: root

- name: Deploy Syncthing stack
  community.docker.docker_compose_v2:
    project_src: "{{ syncthing_data_dir }}"
    state: present

- name: Wait for Syncthing to become healthy
  ansible.builtin.uri:
    url: "http://localhost:{{ syncthing_ui_port }}/rest/noauth/health"
    status_code: [200]
  register: syncthing_health
  until: syncthing_health is not failed
  retries: "{{ syncthing_health_check_retries }}"
  delay: "{{ syncthing_health_check_delay }}"

- name: Get Syncthing API key from config
  ansible.builtin.slurp:
    src: "{{ syncthing_data_dir }}/config/config.xml"
  register: _syncthing_config_raw

- name: Extract API key from config
  ansible.builtin.set_fact:
    _syncthing_api_key: "{{ _syncthing_config_raw.content | b64decode | regex_search('<apikey>([^<]+)</apikey>', '\\1') | first }}"
  no_log: true

- name: Set Syncthing admin password via API
  ansible.builtin.uri:
    url: "http://localhost:{{ syncthing_ui_port }}/rest/config/gui"
    method: PATCH
    headers:
      X-API-Key: "{{ _syncthing_api_key }}"
    body_format: json
    body:
      user: admin
      password: "{{ syncthing_admin_password }}"
    status_code: [200]
  no_log: true

- name: Set default folder path to vault directory via API
  ansible.builtin.uri:
    url: "http://localhost:{{ syncthing_ui_port }}/rest/config/defaults/folder"
    method: PATCH
    headers:
      X-API-Key: "{{ _syncthing_api_key }}"
    body_format: json
    body:
      path: /var/syncthing/vault
    status_code: [200]

- name: Get Syncthing device ID
  ansible.builtin.uri:
    url: "http://localhost:{{ syncthing_ui_port }}/rest/system/status"
    headers:
      X-API-Key: "{{ _syncthing_api_key }}"
    return_content: true
  register: _syncthing_status

- name: Display Syncthing setup information
  ansible.builtin.debug:
    msg: |
      Syncthing is running at http://{{ inventory_hostname }}:{{ syncthing_ui_port }}

      ══════════════════════════════════════════════════════════
      DEVICE ID (copy this to your desktop Syncthing):

      {{ _syncthing_status.json.myID }}

      ══════════════════════════════════════════════════════════

      Admin UI: http://127.0.0.1:{{ syncthing_ui_port }} (localhost only)
      Admin user: admin
      Sync port: {{ syncthing_sync_port }}
      Vault folder: {{ vault_content_dir }}

      Next steps:
        1. Install Syncthing on your desktop (apt install syncthing)
        2. Add this device ID in desktop Syncthing UI
        3. Share your Obsidian vault folder with this device
        4. Accept the share on this server
```

- [ ] **Step 4: Write syncthing handlers/main.yml**

Replace `files/knowledge-vault-setup/roles/syncthing/handlers/main.yml` with:
```yaml
---
- name: restart syncthing
  community.docker.docker_compose_v2:
    project_src: "{{ syncthing_data_dir }}"
    state: restarted
```

- [ ] **Step 5: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/roles/syncthing/
git commit -m "feat: add Syncthing role — deploy, configure, print device ID"
```

---

### Task 3: Quartz Role — Dockerfile, Templates, Tasks

**Files:**
- Create: `files/knowledge-vault-setup/roles/quartz/templates/Dockerfile.j2`
- Create: `files/knowledge-vault-setup/roles/quartz/templates/quartz.config.ts.j2`
- Create: `files/knowledge-vault-setup/roles/quartz/templates/docker-compose.yml.j2`
- Modify: `files/knowledge-vault-setup/roles/quartz/tasks/main.yml`
- Create: `files/knowledge-vault-setup/roles/quartz/molecule/default/tests/test_default.py`

- [ ] **Step 1: Create Molecule test**

Create `files/knowledge-vault-setup/roles/quartz/molecule/default/tests/test_default.py`:
```python
"""Testinfra tests for quartz role."""


def test_quartz_data_directory_exists(host):
    """Verify the Quartz data directory was created."""
    assert host.file("/opt/knowledge-vault/quartz").is_directory


def test_quartz_dockerfile_exists(host):
    """Verify the Dockerfile was templated."""
    dockerfile = host.file("/opt/knowledge-vault/quartz/Dockerfile")
    assert dockerfile.exists


def test_quartz_config_exists(host):
    """Verify quartz.config.ts was templated."""
    config = host.file("/opt/knowledge-vault/quartz/quartz.config.ts")
    assert config.exists
    assert config.contains("Knowledge Vault")


def test_quartz_container_running(host):
    """Verify the Quartz container is running."""
    result = host.run("docker ps --filter name=quartz --format '{{.Status}}'")
    assert "Up" in result.stdout


def test_quartz_port_listening(host):
    """Verify Quartz is listening on port 8080."""
    socket = host.socket("tcp://0.0.0.0:8080")
    assert socket.is_listening


def test_quartz_serves_html(host):
    """Verify Quartz serves HTML content."""
    result = host.run("curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/")
    assert result.stdout.strip() == "200"
```

- [ ] **Step 2: Create Dockerfile.j2**

Create `files/knowledge-vault-setup/roles/quartz/templates/Dockerfile.j2`:
```dockerfile
FROM node:22-slim AS builder
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
WORKDIR /usr/src/app
RUN git clone --depth 1 https://github.com/jackyzha0/quartz.git .
RUN npm ci

FROM node:22-slim
WORKDIR /usr/src/app
COPY --from=builder /usr/src/app /usr/src/app
COPY quartz.config.ts /usr/src/app/quartz.config.ts
RUN mkdir -p /usr/src/app/content
EXPOSE 8080
CMD ["npx", "quartz", "build", "--serve", "--port", "8080"]
```

- [ ] **Step 3: Create quartz.config.ts.j2**

Create `files/knowledge-vault-setup/roles/quartz/templates/quartz.config.ts.j2`:
```typescript
import { QuartzConfig } from "./quartz/cfg"
import * as Plugin from "./quartz/plugins"

const config: QuartzConfig = {
  configuration: {
    pageTitle: "{{ quartz_page_title }}",
    pageTitleSuffix: "",
    enableSPA: true,
    enablePopovers: true,
    analytics: null,
    locale: "en-US",
    baseUrl: "{{ vault_hostname }}.{{ saved_domain | default('localhost') }}",
    ignorePatterns: ["private", "templates", ".obsidian"],
    defaultDateType: "modified",
    theme: {
      fontOrigin: "googleFonts",
      cdnCaching: true,
      typography: {
        header: "Schibsted Grotesk",
        body: "Source Sans Pro",
        code: "IBM Plex Mono",
      },
      colors: {
        lightMode: {
          light: "#faf8f8",
          lightgray: "#e5e5e5",
          gray: "#b8b8b8",
          darkgray: "#4e4e4e",
          dark: "#2b2b2b",
          secondary: "#284b63",
          tertiary: "#84a59d",
          highlight: "rgba(143, 159, 169, 0.15)",
          textHighlight: "#fff23688",
        },
        darkMode: {
          light: "#161618",
          lightgray: "#393639",
          gray: "#646464",
          darkgray: "#d4d4d4",
          dark: "#ebebec",
          secondary: "#7b97aa",
          tertiary: "#84a59d",
          highlight: "rgba(143, 159, 169, 0.15)",
          textHighlight: "#fff23688",
        },
      },
    },
  },
  plugins: {
    transformers: [
      Plugin.FrontMatter(),
      Plugin.CreatedModifiedDate({
        priority: ["filesystem"],
      }),
      Plugin.SyntaxHighlighting({
        theme: {
          light: "github-light",
          dark: "github-dark",
        },
      }),
      Plugin.ObsidianFlavoredMarkdown({ enableInHtmlEmbed: false }),
      Plugin.GitHubFlavoredMarkdown(),
      Plugin.TableOfContents(),
      Plugin.CrawlLinks({ markdownLinkResolution: "shortest" }),
      Plugin.Description(),
      Plugin.Latex({ renderEngine: "katex" }),
    ],
    filters: [Plugin.RemoveDrafts()],
    emitters: [
      Plugin.AliasRedirects(),
      Plugin.ComponentResources(),
      Plugin.ContentPage(),
      Plugin.FolderPage(),
      Plugin.TagPage(),
      Plugin.ContentIndex({
        enableSiteMap: false,
        enableRSS: false,
      }),
      Plugin.Assets(),
      Plugin.Static(),
      Plugin.NotFoundPage(),
    ],
  },
}

export default config
```

- [ ] **Step 4: Create docker-compose.yml.j2**

Create `files/knowledge-vault-setup/roles/quartz/templates/docker-compose.yml.j2`:
```yaml
services:
  quartz:
    container_name: {{ quartz_container_name }}
    build:
      context: {{ quartz_data_dir }}
      dockerfile: Dockerfile
    restart: {{ quartz_restart_policy }}
    ports:
      - "{{ quartz_port }}:8080"
    volumes:
      - {{ vault_content_dir }}:/usr/src/app/content:ro
    networks:
      - {{ docker_network_name }}

networks:
  {{ docker_network_name }}:
    external: true
```

- [ ] **Step 5: Write quartz tasks/main.yml**

Replace `files/knowledge-vault-setup/roles/quartz/tasks/main.yml` with:
```yaml
---
- name: Create Quartz data directory
  ansible.builtin.file:
    path: "{{ quartz_data_dir }}"
    state: directory
    mode: "0755"
    owner: root
    group: root

- name: Template Quartz Dockerfile
  ansible.builtin.template:
    src: Dockerfile.j2
    dest: "{{ quartz_data_dir }}/Dockerfile"
    mode: "0644"
    owner: root
    group: root
  register: _quartz_dockerfile

- name: Template Quartz config
  ansible.builtin.template:
    src: quartz.config.ts.j2
    dest: "{{ quartz_data_dir }}/quartz.config.ts"
    mode: "0644"
    owner: root
    group: root
  register: _quartz_config

- name: Template Docker Compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ quartz_data_dir }}/docker-compose.yml"
    mode: "0600"
    owner: root
    group: root

- name: Create placeholder index if content dir is empty
  ansible.builtin.copy:
    content: |
      ---
      title: Welcome
      ---

      # Knowledge Vault

      This vault is empty. Sync your Obsidian vault via Syncthing to see your notes here.
    dest: "{{ vault_content_dir }}/index.md"
    mode: "0644"
    owner: "{{ syncthing_puid }}"
    group: "{{ syncthing_pgid }}"
    force: false

- name: Build and deploy Quartz stack
  community.docker.docker_compose_v2:
    project_src: "{{ quartz_data_dir }}"
    state: present
    build: always
  when: _quartz_dockerfile.changed or _quartz_config.changed

- name: Deploy Quartz stack (no rebuild)
  community.docker.docker_compose_v2:
    project_src: "{{ quartz_data_dir }}"
    state: present
  when: not (_quartz_dockerfile.changed or _quartz_config.changed)

- name: Wait for Quartz to become healthy
  ansible.builtin.uri:
    url: "http://localhost:{{ quartz_port }}/"
    status_code: [200]
  register: quartz_health
  until: quartz_health is not failed
  retries: "{{ quartz_health_check_retries }}"
  delay: "{{ quartz_health_check_delay }}"

- name: Display Quartz access information
  ansible.builtin.debug:
    msg: |
      Quartz is running at http://{{ inventory_hostname }}:{{ quartz_port }}

      Site title: {{ quartz_page_title }}
      Content directory: {{ vault_content_dir }}
      Public URL: https://{{ vault_hostname }}.{{ hostvars['localhost']['saved_domain'] | default('your-domain') }}

      The site will auto-rebuild when vault files change via Syncthing.
```

- [ ] **Step 6: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/roles/quartz/
git commit -m "feat: add Quartz role — Dockerfile, config, deploy, auto-rebuild"
```

---

### Task 4: Molecule Test Configuration

**Files:**
- Create: `files/knowledge-vault-setup/roles/syncthing/molecule/default/molecule.yml`
- Create: `files/knowledge-vault-setup/roles/syncthing/molecule/default/converge.yml`
- Create: `files/knowledge-vault-setup/roles/syncthing/molecule/default/vars/test-vars.yml`
- Create: `files/knowledge-vault-setup/roles/quartz/molecule/default/molecule.yml`
- Create: `files/knowledge-vault-setup/roles/quartz/molecule/default/converge.yml`
- Create: `files/knowledge-vault-setup/roles/quartz/molecule/default/vars/test-vars.yml`

- [ ] **Step 1: Create Syncthing molecule.yml**

Create `files/knowledge-vault-setup/roles/syncthing/molecule/default/molecule.yml`:
```yaml
---
dependency:
  name: galaxy
  options:
    requirements-file: ${MOLECULE_PROJECT_DIRECTORY}/../../../../../../requirements.yml
driver:
  name: docker
platforms:
  - name: syncthing-test
    image: geerlingguy/docker-ubuntu2404-ansible
    command: /lib/systemd/systemd
    privileged: true
    pre_build_image: true
    cgroupns_mode: host
    tmpfs:
      - /run
      - /tmp
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
provisioner:
  name: ansible
  config_options:
    defaults:
      roles_path: ../../
  playbooks:
    converge: converge.yml
verifier:
  name: testinfra
  options:
    v: true
scenario:
  test_sequence:
    - dependency
    - cleanup
    - destroy
    - syntax
    - create
    - prepare
    - converge
    - verify
    - cleanup
    - destroy
```

- [ ] **Step 2: Create Syncthing test-vars.yml**

Create `files/knowledge-vault-setup/roles/syncthing/molecule/default/vars/test-vars.yml`:
```yaml
---
syncthing_container_name: syncthing
syncthing_image: "syncthing/syncthing:1.29"
syncthing_sync_port: 22000
syncthing_ui_port: 8384
syncthing_data_dir: /opt/knowledge-vault/syncthing
syncthing_restart_policy: unless-stopped
syncthing_health_check_retries: 30
syncthing_health_check_delay: 10
syncthing_puid: "1000"
syncthing_pgid: "1000"
syncthing_admin_password: testpassword
vault_content_dir: /opt/knowledge-vault/content
docker_network_name: vault-net
```

- [ ] **Step 3: Create Syncthing converge.yml**

Create `files/knowledge-vault-setup/roles/syncthing/molecule/default/converge.yml`:
```yaml
---
- name: Converge
  hosts: all
  become: true
  vars_files:
    - vars/test-vars.yml
  pre_tasks:
    - name: Create Docker config directory
      ansible.builtin.file:
        path: /etc/docker
        state: directory
        mode: "0755"
    - name: Configure Docker to use vfs storage driver
      ansible.builtin.copy:
        content: |
          {
            "storage-driver": "vfs"
          }
        dest: /etc/docker/daemon.json
        mode: "0644"
    - name: Install Docker prerequisites
      ansible.builtin.apt:
        name:
          - ca-certificates
          - curl
          - gnupg
        state: present
        update_cache: true
    - name: Create keyrings directory
      ansible.builtin.file:
        path: /etc/apt/keyrings
        state: directory
        mode: "0755"
    - name: Download Docker GPG key
      ansible.builtin.get_url:
        url: "https://download.docker.com/linux/{{ ansible_distribution | lower }}/gpg"
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"
    - name: Add Docker repository
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
          https://download.docker.com/linux/{{ ansible_distribution | lower }}
          {{ ansible_distribution_release }} stable
        filename: docker
        state: present
    - name: Install Docker packages
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-compose-plugin
          - python3-docker
        state: present
        update_cache: true
    - name: Ensure Docker service is started
      ansible.builtin.systemd:
        name: docker
        state: started
        enabled: true
    - name: Pre-create secrets directory
      ansible.builtin.file:
        path: "{{ lookup('env', 'HOME') }}/.homelab-secrets/knowledge-vault"
        state: directory
        mode: "0700"
    - name: Pre-create syncthing_admin_password file
      ansible.builtin.copy:
        content: "testpassword"
        dest: "{{ lookup('env', 'HOME') }}/.homelab-secrets/knowledge-vault/syncthing_admin_password"
        mode: "0600"
        force: false
  roles:
    - role: syncthing
```

- [ ] **Step 4: Create Quartz molecule.yml**

Create `files/knowledge-vault-setup/roles/quartz/molecule/default/molecule.yml`:
```yaml
---
dependency:
  name: galaxy
  options:
    requirements-file: ${MOLECULE_PROJECT_DIRECTORY}/../../../../../../requirements.yml
driver:
  name: docker
platforms:
  - name: quartz-test
    image: geerlingguy/docker-ubuntu2404-ansible
    command: /lib/systemd/systemd
    privileged: true
    pre_build_image: true
    cgroupns_mode: host
    tmpfs:
      - /run
      - /tmp
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
provisioner:
  name: ansible
  config_options:
    defaults:
      roles_path: ../../
  playbooks:
    converge: converge.yml
verifier:
  name: testinfra
  options:
    v: true
scenario:
  test_sequence:
    - dependency
    - cleanup
    - destroy
    - syntax
    - create
    - prepare
    - converge
    - verify
    - cleanup
    - destroy
```

- [ ] **Step 5: Create Quartz test-vars.yml**

Create `files/knowledge-vault-setup/roles/quartz/molecule/default/vars/test-vars.yml`:
```yaml
---
quartz_container_name: quartz
quartz_port: 8080
quartz_data_dir: /opt/knowledge-vault/quartz
quartz_restart_policy: unless-stopped
quartz_health_check_retries: 60
quartz_health_check_delay: 10
quartz_page_title: "Knowledge Vault"
vault_content_dir: /opt/knowledge-vault/content
vault_hostname: "kb"
saved_domain: "test.local"
syncthing_puid: "1000"
syncthing_pgid: "1000"
docker_network_name: vault-net
```

- [ ] **Step 6: Create Quartz converge.yml**

Create `files/knowledge-vault-setup/roles/quartz/molecule/default/converge.yml`:
```yaml
---
- name: Converge
  hosts: all
  become: true
  vars_files:
    - vars/test-vars.yml
  pre_tasks:
    - name: Create Docker config directory
      ansible.builtin.file:
        path: /etc/docker
        state: directory
        mode: "0755"
    - name: Configure Docker to use vfs storage driver
      ansible.builtin.copy:
        content: |
          {
            "storage-driver": "vfs"
          }
        dest: /etc/docker/daemon.json
        mode: "0644"
    - name: Install Docker prerequisites
      ansible.builtin.apt:
        name:
          - ca-certificates
          - curl
          - gnupg
        state: present
        update_cache: true
    - name: Create keyrings directory
      ansible.builtin.file:
        path: /etc/apt/keyrings
        state: directory
        mode: "0755"
    - name: Download Docker GPG key
      ansible.builtin.get_url:
        url: "https://download.docker.com/linux/{{ ansible_distribution | lower }}/gpg"
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"
    - name: Add Docker repository
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
          https://download.docker.com/linux/{{ ansible_distribution | lower }}
          {{ ansible_distribution_release }} stable
        filename: docker
        state: present
    - name: Install Docker packages
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-compose-plugin
          - python3-docker
        state: present
        update_cache: true
    - name: Ensure Docker service is started
      ansible.builtin.systemd:
        name: docker
        state: started
        enabled: true
    - name: Create vault-net Docker network
      community.docker.docker_network:
        name: vault-net
        state: present
    - name: Create vault content directory with placeholder
      ansible.builtin.file:
        path: /opt/knowledge-vault/content
        state: directory
        mode: "0755"
  roles:
    - role: quartz
```

- [ ] **Step 7: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/roles/syncthing/molecule/ files/knowledge-vault-setup/roles/quartz/molecule/
git commit -m "test: add Molecule tests for Syncthing and Quartz roles"
```

---

### Task 5: Main setup.yml Playbook

**Files:**
- Create: `files/knowledge-vault-setup/setup.yml`

- [ ] **Step 1: Write setup.yml**

Create `files/knowledge-vault-setup/setup.yml`:
```yaml
---
# =============================================================================
# Knowledge Vault Setup (Syncthing + Quartz)
# =============================================================================
# Deploys Syncthing + Quartz for a private Obsidian vault web viewer.
#
# Usage:
#   ansible-playbook files/knowledge-vault-setup/setup.yml \
#     -i files/knowledge-vault-setup/inventory/hosts.ini \
#     --ask-become-pass
# =============================================================================

- name: Load saved homelab configuration (if available)
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Check for homelab setup vars
      ansible.builtin.stat:
        path: "{{ lookup('env', 'HOME') }}/.homelab-setup-vars.yml"
      register: _homelab_vars_stat

    - name: Load homelab setup vars
      ansible.builtin.include_vars:
        file: "{{ lookup('env', 'HOME') }}/.homelab-setup-vars.yml"
      when: _homelab_vars_stat.stat.exists

    - name: Check Vault availability
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../common/vault-integration/check.yml"

    - name: Load secrets from Vault
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../common/vault-integration/load.yml"
      vars:
        vault_service_name: "knowledge-vault"
      when: _vault_available | bool

- name: Gather host details
  hosts: localhost
  connection: local
  gather_facts: false
  vars_prompt:
    - name: target_host_ip
      prompt: |

        ══════════════════════════════════════════════
          Knowledge Vault Setup Wizard
          (Syncthing + Quartz)
        ══════════════════════════════════════════════

        [1/3] IP or hostname of the target host
      default: "10.0.1.2"
      private: false

    - name: target_ssh_user
      prompt: "[2/3] SSH user for the target host"
      private: false

    - name: syncthing_admin_password
      prompt: "[3/3] Syncthing admin password"
      default: "{{ hostvars['localhost']['_vault_secrets']['syncthing_admin_password'] | default('') }}"
      private: true
      confirm: true

  tasks:
    - name: Add target host to dynamic inventory
      ansible.builtin.add_host:
        name: "{{ target_host_ip }}"
        groups: vault_hosts
        ansible_user: "{{ target_ssh_user }}"
        ansible_python_interpreter: /usr/bin/python3
        syncthing_admin_password: "{{ syncthing_admin_password }}"
      no_log: true

- name: Store secrets to Vault
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Store secrets to Vault
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../common/vault-integration/store.yml"
      vars:
        vault_service_name: "knowledge-vault"
        vault_secrets_data:
          syncthing_admin_password: "{{ hostvars[groups['vault_hosts'][0]]['syncthing_admin_password'] | default('') }}"
      when: _vault_available | default(false) | bool

- name: Install Docker, deploy Syncthing and Quartz
  hosts: vault_hosts
  become: true
  roles:
    - docker
    - syncthing
    - quartz

- name: Integrate with secure homelab (Caddy + Pi-hole + Homepage)
  hosts: localhost
  connection: local
  become: true
  gather_facts: true
  vars:
    _target_host_ip: "{{ hostvars['localhost']['target_host_ip'] }}"
    _caddy_proxy_host: "{{ docker_gateway_ip | default('172.20.0.1') if _target_host_ip in ['localhost', '127.0.0.1', '::1'] else _target_host_ip }}"
    vault_hostname: "{{ hostvars[groups['vault_hosts'][0]]['vault_hostname'] | default('kb') }}"
    quartz_port: "{{ hostvars[groups['vault_hosts'][0]]['quartz_port'] | default(8080) }}"
  tasks:
    - name: Integrate when secure homelab is configured
      when: hostvars['localhost']['_homelab_vars_stat'].stat.exists
      block:
        - name: Add Cloudflare Tunnel DNS route for Knowledge Vault
          ansible.builtin.command: >
            cloudflared tunnel route dns {{ saved_cf_tunnel_name }}
            {{ vault_hostname }}.{{ saved_domain }}
          environment:
            TUNNEL_ORIGIN_CERT: "{{ lookup('env', 'HOME') }}/.cloudflared/cert.pem"
          register: _vault_cf_dns
          changed_when: _vault_cf_dns.rc == 0
          failed_when: false
          become: false
          when: saved_cf_tunnel_name is defined and saved_cf_tunnel_name | length > 0

        - name: Add Knowledge Vault to Caddy config
          ansible.builtin.blockinfile:
            path: /opt/homelab/caddy/Caddyfile
            marker: "# {mark} KNOWLEDGE_VAULT"
            unsafe_writes: true
            block: |
              http://{{ vault_hostname }}.{{ saved_domain }} {
                import rate_limit
                import proxy_headers
                import authelia
                reverse_proxy http://{{ _caddy_proxy_host }}:{{ quartz_port }}
              }
          notify: reload caddy

        - name: Add Pi-hole local DNS record for Knowledge Vault
          ansible.builtin.command: >
            docker exec pihole sh -c
            'grep -qF "{{ vault_hostname }}.{{ saved_domain }}" /etc/pihole/custom.list ||
             (echo "{{ ansible_default_ipv4.address }} {{ vault_hostname }}.{{ saved_domain }}" >> /etc/pihole/custom.list && echo CHANGED)'
          register: _pihole_dns
          changed_when: "'CHANGED' in _pihole_dns.stdout"

        - name: Reload Pi-hole DNS
          ansible.builtin.command: docker exec pihole pihole restartdns reload
          changed_when: true
          when: _pihole_dns.changed

        - name: Replace Obsidian Sync Homepage entry with Knowledge Vault
          ansible.builtin.blockinfile:
            path: /opt/homelab/homepage/services.yaml
            marker: "    # {mark} OBSIDIAN_LIVESYNC"
            unsafe_writes: true
            block: |2
                  - Knowledge Vault:
                      icon: obsidian.png
                      href: "https://{{ vault_hostname }}.{{ saved_domain }}"
                      description: "Personal knowledge base"

    - name: Add /etc/hosts fallback when secure homelab is not configured
      ansible.builtin.lineinfile:
        path: /etc/hosts
        line: "{{ _target_host_ip }} {{ vault_hostname }}.home"
        state: present
      when: not hostvars['localhost']['_homelab_vars_stat'].stat.exists

  handlers:
    - name: reload caddy
      ansible.builtin.shell: |
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile
      changed_when: true
```

- [ ] **Step 2: Verify syntax**

```bash
cd /home/kamil-rybacki/Code/ansible
ansible-playbook files/knowledge-vault-setup/setup.yml --syntax-check
```

Expected: `playbook: setup.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/setup.yml
git commit -m "feat: add main setup.yml for Knowledge Vault (Syncthing + Quartz)"
```

---

### Task 6: README Documentation

**Files:**
- Create: `files/knowledge-vault-setup/README.md`

- [ ] **Step 1: Write README**

Create `files/knowledge-vault-setup/README.md`:
```markdown
# Knowledge Vault Setup

Deploys [Syncthing](https://syncthing.net/) + [Quartz](https://quartz.jzhao.xyz/) to serve an Obsidian vault as a private, browsable website with graph view, backlinks, and full-text search.

## Prerequisites

- Target host running Ubuntu 22.04+ with SSH access
- `ansible-galaxy collection install -r requirements.yml`
- (Optional) HashiCorp Vault configured at `~/.vault-ansible.yml`
- (Optional) Secure homelab stack (Caddy, Authelia, Pi-hole, Homepage)
- Syncthing installed on your Linux desktop

## Usage

```bash
ansible-playbook files/knowledge-vault-setup/setup.yml \
  -i files/knowledge-vault-setup/inventory/hosts.ini \
  --ask-become-pass
```

The wizard prompts for:

| Prompt | Default | Description |
|--------|---------|-------------|
| Target host IP | 10.0.1.2 | Shared database host |
| SSH user | — | SSH user on the target host |
| Syncthing admin password | (from Vault) | Web UI admin password |

## What Gets Deployed

- **Syncthing** container — receives vault files from your desktop via P2P sync
- **Quartz** container — renders vault as a static website with auto-rebuild on file change
- Shared volume (`vault-content`) between Syncthing and Quartz
- (If homelab stack present) Caddy reverse proxy at `kb.<domain>`, Pi-hole DNS, Homepage entry

## Desktop Setup (One-time)

After the playbook runs:

1. Install Syncthing: `sudo apt install syncthing`
2. Start Syncthing: `syncthing` (or enable the systemd service)
3. Open `http://localhost:8384` in your browser
4. Go to Actions > Show ID on the **server** Syncthing (device ID is printed in playbook output)
5. In desktop Syncthing: Add Remote Device > paste the server device ID
6. Add Folder > select your Obsidian vault directory > share with the server device
7. On the server Syncthing, accept the incoming folder share

Your vault will sync and Quartz will auto-rebuild the site.

## Secrets

Stored in Vault at `secret/homelab/knowledge-vault`:

| Key | Description |
|-----|-------------|
| `syncthing_admin_password` | Syncthing Web UI admin password |

Local fallback: `~/.homelab-secrets/knowledge-vault/`

## Testing

```bash
cd files/knowledge-vault-setup/roles/syncthing
molecule test

cd ../quartz
molecule test
```

## Architecture

```
Desktop (Obsidian + Syncthing) → Syncthing container → shared volume → Quartz → Caddy (kb.<domain>)
Desktop (Obsidian + LiveSync)  → CouchDB → Mobile Obsidian (editing)
```

Quartz provides read-only web access. LiveSync + CouchDB handles mobile editing.
```

- [ ] **Step 2: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add files/knowledge-vault-setup/README.md
git commit -m "docs: add README for Knowledge Vault setup"
```

---

### Task 7: Lint, Validate, Final Checks

**Files:** No new files — validation only.

- [ ] **Step 1: Syntax check**

```bash
cd /home/kamil-rybacki/Code/ansible
ansible-playbook files/knowledge-vault-setup/setup.yml --syntax-check
```

Expected: `playbook: setup.yml` (no errors)

- [ ] **Step 2: Verify all files committed**

```bash
cd /home/kamil-rybacki/Code/ansible
git status files/knowledge-vault-setup/
```

Expected: Clean working tree.

- [ ] **Step 3: Verify file count**

```bash
find files/knowledge-vault-setup/ -type f | wc -l
```

Expected: ~20 files.
