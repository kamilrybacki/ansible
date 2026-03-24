# OpenClaw Metrics Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python Prometheus exporter that monitors OpenClaw's LLM usage (tokens, costs, latency, errors) and pipes it into the existing Grafana/Mimir/Alloy monitoring stack with a provisioned dashboard.

**Architecture:** A Python container (`openclaw-metrics`) reads OpenClaw session JSONL files and gateway logs via shared volumes, exposes `/metrics` on port 9101, which Alloy scrapes into Mimir. A provisioned Grafana dashboard visualizes the data.

**Tech Stack:** Python 3.12, prometheus_client, watchdog, Ansible/Jinja2, Grafana JSON dashboard, Alloy River config

**Spec:** `docs/superpowers/specs/2026-03-24-openclaw-metrics-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/exporter.py` | Main exporter: SessionWatcher + LogTailer + MetricsServer + BurnRateCalculator |
| `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/Dockerfile` | Python 3.12-slim container with deps |
| `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/requirements.txt` | prometheus_client, watchdog |
| `monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json` | Grafana dashboard JSON |
| `monitoring/grafana-stack-setup/roles/grafana-stack/templates/provisioning/dashboards.yml.j2` | Dashboard provider config |

### Modified Files

| File | Change |
|------|--------|
| `ai/openclaw-setup/roles/openclaw/templates/docker-compose.yml.j2` | Add openclaw-metrics service + openclaw-logs volume |
| `ai/openclaw-setup/roles/openclaw/defaults/main.yml` | Add `openclaw_metrics_enabled`, `openclaw_metrics_port` |
| `ai/openclaw-setup/roles/openclaw/tasks/main.yml` | Copy exporter files, build container |
| `monitoring/grafana-stack-setup/roles/grafana-stack/templates/alloy.river.j2` | Add conditional openclaw scrape block |
| `monitoring/grafana-stack-setup/group_vars/all.yml` | Add `openclaw_metrics_host`, `openclaw_metrics_port` |
| `monitoring/grafana-stack-setup/roles/grafana-stack/templates/docker-compose.yml.j2` | Add dashboards volume mount |
| `monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml` | Add dashboard provisioning tasks |

---

### Task 1: Create the Python Exporter

**Files:**
- Create: `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/exporter.py`
- Create: `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/Dockerfile`
- Create: `ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/requirements.txt`

- [ ] **Step 1: Create requirements.txt**

```
ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/requirements.txt
```

```
prometheus_client==0.21.1
watchdog==6.0.0
```

- [ ] **Step 2: Create Dockerfile**

```
ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/Dockerfile
```

```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY exporter.py .

CMD ["python3", "-u", "exporter.py"]
```

- [ ] **Step 3: Create exporter.py — imports and metrics definitions**

```
ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/exporter.py
```

Write the complete exporter with these components:

**Metrics definitions** (module-level):
- All counters, histograms, gauges from the spec's metrics catalog
- Histogram buckets: `[0.5, 1, 5, 10, 30, 60, 120, 300]`
- `CHARS_PER_TOKEN = 4` constant for estimation

**`estimate_tokens(text: str) -> int`**:
- Return `max(1, len(text) // CHARS_PER_TOKEN)`

**`parse_usage(message: dict, agent: str)`**:
- Extract `message.usage` dict from session JSONL entry
- Read `input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens`
- Read `cost.input`, `cost.output`, `cost.total`
- Extract `provider` and `model` from message metadata (or `"unknown"`)
- If both input and output are 0, estimate from message content
- Increment all relevant counters
- Track cost in the burn rate deque

**`class SessionWatcher(FileSystemEventHandler)`**:
- On `on_modified` for `.jsonl` files: read new lines from last position
- Maintain `file_positions: dict[str, int]` for seek offsets
- Parse each new JSON line, call `parse_usage()`
- On startup: `scan_existing()` — walk all `agents/*/sessions/*.jsonl`, parse all lines

**`class LogTailer(threading.Thread)`**:
- `daemon = True`
- Scan `LOGS_DIR` for `openclaw-*.log` files
- Tail newest file, detect new daily files
- Parse each JSON line for:
  - `embedded_run_agent_end` → extract `model`, `provider`, `isError`, `error`, increment `openclaw_requests_total`, `openclaw_errors_total`
  - `telegram` `sendMessage` → increment `openclaw_telegram_messages_total` with `direction="out"`
  - `telegram` `starting provider` → note heartbeat ok
  - Agent run timing (if available in logs)

**`class BurnRateCalculator(threading.Thread)`**:
- `daemon = True`
- Maintain `collections.deque` of `(timestamp, cost)` tuples, maxlen=3600
- Every 60s: sum costs in last hour, update `openclaw_cost_rate_dollars_per_hour` gauge per provider

**`main()`**:
- Read env vars: `SESSIONS_DIR`, `LOGS_DIR`, `METRICS_PORT`
- Run `SessionWatcher.scan_existing()`
- Start watchdog Observer
- Start LogTailer thread
- Start BurnRateCalculator thread
- Start `prometheus_client.start_http_server(port)`
- `signal.pause()` to keep alive

The full exporter should be approximately 250-350 lines of Python. Config is entirely via env vars (no Jinja2 templating).

- [ ] **Step 4: Test exporter locally**

```bash
cd ai/openclaw-setup/roles/openclaw/files/openclaw-metrics
docker build -t openclaw-metrics-test .
# Quick smoke test — should start and expose /metrics
docker run --rm -e SESSIONS_DIR=/data -e LOGS_DIR=/data -e METRICS_PORT=9101 -p 9101:9101 openclaw-metrics-test &
sleep 3
curl -s http://localhost:9101/metrics | grep "openclaw_"
docker stop $(docker ps -q --filter ancestor=openclaw-metrics-test)
```

Expected: Prometheus metrics output with `openclaw_info`, `openclaw_tokens_input_total`, etc. (all at 0 since no data).

- [ ] **Step 5: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/files/openclaw-metrics/
git commit -m "feat(openclaw): add Python Prometheus metrics exporter

SessionWatcher (JSONL), LogTailer (gateway logs), BurnRateCalculator,
token estimation for providers that report 0. Exposes /metrics on :9101."
```

---

### Task 2: Integrate Exporter into Docker Compose

**Files:**
- Modify: `ai/openclaw-setup/roles/openclaw/templates/docker-compose.yml.j2`
- Modify: `ai/openclaw-setup/roles/openclaw/defaults/main.yml`

- [ ] **Step 1: Add defaults**

Add to `ai/openclaw-setup/roles/openclaw/defaults/main.yml` after the community agents section and before `# --- Security ---`:

```yaml
# --- Metrics exporter ---
openclaw_metrics_enabled: true
openclaw_metrics_port: 9101
```

- [ ] **Step 2: Modify docker-compose template**

In `ai/openclaw-setup/roles/openclaw/templates/docker-compose.yml.j2`:

**a)** Add `openclaw-logs` volume to the OpenClaw container's volumes:
```yaml
  openclaw:
    volumes:
      - ./data:/app/data
      - ./openclaw-home:/home/node/.openclaw
      - openclaw-logs:/tmp/openclaw
```

**b)** Ensure `openclaw-net` is always created (currently conditional on Ollama). Change the network conditionals so `openclaw-net` exists when either Ollama OR metrics is enabled:
```jinja2
{% if openclaw_ollama_enabled or openclaw_metrics_enabled %}
      - openclaw-net
{% endif %}
```

**c)** Add the metrics service block (conditional on `openclaw_metrics_enabled`):

```yaml
{% if openclaw_metrics_enabled %}
  openclaw-metrics:
    build:
      context: ./openclaw-metrics
    container_name: openclaw-metrics
    ports:
      - "127.0.0.1:{{ openclaw_metrics_port }}:9101"
    volumes:
      - ./openclaw-home:/data/openclaw-home:ro
      - openclaw-logs:/data/openclaw-logs:ro
    environment:
      METRICS_PORT: "9101"
      SESSIONS_DIR: "/data/openclaw-home"
      LOGS_DIR: "/data/openclaw-logs"
    networks:
      - openclaw-net
    restart: unless-stopped
    mem_limit: 256m
    cpus: 0.5
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:9101/metrics')"]
      interval: 30s
      timeout: 5s
      retries: 3
    depends_on:
      openclaw:
        condition: service_healthy
{% endif %}
```

**d)** Add `openclaw-logs` named volume and make `openclaw-net` conditional on either feature:

```yaml
{% if openclaw_metrics_enabled %}
volumes:
  openclaw-logs:
{% endif %}

networks:
  homelab-net:
    external: true
{% if openclaw_ollama_enabled or openclaw_metrics_enabled %}
  openclaw-net:
    driver: bridge
{% endif %}
```

- [ ] **Step 3: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/templates/docker-compose.yml.j2 ai/openclaw-setup/roles/openclaw/defaults/main.yml
git commit -m "feat(openclaw): add openclaw-metrics container to docker-compose

Conditional on openclaw_metrics_enabled. Shares session data via bind
mount and gateway logs via openclaw-logs named volume. Exposes :9101
on loopback only. Resource limits: 256MB RAM, 0.5 CPU."
```

---

### Task 3: Add Ansible Tasks for Exporter Deployment

**Files:**
- Modify: `ai/openclaw-setup/roles/openclaw/tasks/main.yml`

- [ ] **Step 1: Add exporter deployment tasks**

Insert after the community agents block and before the Telegram channel block. The tasks copy the exporter files into the install directory so `docker compose build` can find them:

```yaml
# --- Metrics exporter ---
- name: Deploy metrics exporter
  when: openclaw_metrics_enabled | default(false) | bool
  block:
    - name: Create openclaw-metrics build directory
      ansible.builtin.file:
        path: "{{ openclaw_install_dir }}/openclaw-metrics"
        state: directory
        mode: "0755"

    - name: Copy metrics exporter files
      ansible.builtin.copy:
        src: "openclaw-metrics/{{ item }}"
        dest: "{{ openclaw_install_dir }}/openclaw-metrics/{{ item }}"
        mode: "0644"
      loop:
        - exporter.py
        - Dockerfile
        - requirements.txt
      notify: Restart openclaw
```

- [ ] **Step 2: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/tasks/main.yml
git commit -m "feat(openclaw): add Ansible tasks to deploy metrics exporter files"
```

---

### Task 4: Add Alloy Scrape Config

**Files:**
- Modify: `monitoring/grafana-stack-setup/roles/grafana-stack/templates/alloy.river.j2`
- Modify: `monitoring/grafana-stack-setup/group_vars/all.yml`

- [ ] **Step 1: Add defaults to group_vars**

Append to `monitoring/grafana-stack-setup/group_vars/all.yml`:

```yaml

# OpenClaw metrics exporter (set to "127.0.0.1" when deployed)
openclaw_metrics_host: ""
openclaw_metrics_port: 9101
```

- [ ] **Step 2: Add scrape block to alloy.river.j2**

Insert before the `// ── Remote write endpoints` section (before line 86):

```river
{% if openclaw_metrics_host | default('') | length > 0 %}
// ── OpenClaw metrics ───────────────────────────────────────────────────────
prometheus.scrape "openclaw" {
  targets         = [{"__address__" = "{{ openclaw_metrics_host }}:{{ openclaw_metrics_port }}"}]
  metrics_path    = "/metrics"
  forward_to      = [prometheus.relabel.openclaw_labels.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "openclaw_labels" {
  forward_to = [prometheus.remote_write.mimir.receiver]

  rule {
    target_label = "job"
    replacement  = "openclaw"
  }
  rule {
    target_label = "instance"
    replacement  = "{{ openclaw_metrics_host }}"
  }
}
{% endif %}
```

- [ ] **Step 3: Commit**

```bash
git add monitoring/grafana-stack-setup/roles/grafana-stack/templates/alloy.river.j2 monitoring/grafana-stack-setup/group_vars/all.yml
git commit -m "feat(monitoring): add Alloy scrape config for OpenClaw metrics

Conditional on openclaw_metrics_host being set. Scrapes 127.0.0.1:9101
every 60s, relabels with job=openclaw. Follows LibreNMS pattern."
```

---

### Task 5: Add Grafana Dashboard Provisioning

**Files:**
- Create: `monitoring/grafana-stack-setup/roles/grafana-stack/templates/provisioning/dashboards.yml.j2`
- Create: `monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json`
- Modify: `monitoring/grafana-stack-setup/roles/grafana-stack/templates/docker-compose.yml.j2`
- Modify: `monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml`

- [ ] **Step 1: Create dashboard provider config**

```
monitoring/grafana-stack-setup/roles/grafana-stack/templates/provisioning/dashboards.yml.j2
```

```yaml
apiVersion: 1

providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 2: Create OpenClaw Grafana dashboard JSON**

```
monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json
```

Create a Grafana dashboard JSON with:

**Dashboard metadata:**
- Title: "OpenClaw LLM Metrics"
- UID: `openclaw-llm-metrics`
- Tags: `["openclaw", "llm", "ai"]`
- Refresh: 1m
- Time range: Last 24h

**Row 1 — Overview (4 stat panels):**
- Total tokens today: `sum(increase(openclaw_tokens_input_total[24h])) + sum(increase(openclaw_tokens_output_total[24h]))`
- Total cost today: `sum(increase(openclaw_cost_dollars_total[24h]))`
- Requests/min: `sum(rate(openclaw_requests_total[5m])) * 60`
- Active sessions: `sum(openclaw_active_sessions)`

**Row 2 — Provider Breakdown (3 panels):**
- Cost per provider (stacked area): `sum by (provider) (increase(openclaw_cost_dollars_total[1h]))`
- Requests per provider (bar): `sum by (provider) (increase(openclaw_requests_total[1h]))`
- Error rate per provider (time series): `sum by (provider) (rate(openclaw_errors_total[5m]))`

**Row 3 — Agent Activity (3 panels):**
- Requests per agent (pie): `sum by (agent) (increase(openclaw_requests_total[24h]))`
- Model usage (bar): `sum by (model) (increase(openclaw_requests_total[24h]))`
- Telegram throughput (time series): `sum by (direction) (rate(openclaw_telegram_messages_total[5m]))`

**Row 4 — Operational (5 panels):**
- Latency p50/p95/p99 (time series): `histogram_quantile(0.5, rate(openclaw_request_duration_seconds_bucket[5m]))` etc.
- Cache hit ratio (gauge): `sum(rate(openclaw_tokens_cache_read_total[1h])) / (sum(rate(openclaw_tokens_cache_read_total[1h])) + sum(rate(openclaw_tokens_cache_write_total[1h])))`
- Heartbeat status (stat): `openclaw_heartbeat_status`
- Cost burn rate (stat): `sum(openclaw_cost_rate_dollars_per_hour)`
- Estimated vs reported tokens (time series): `sum(rate(openclaw_tokens_estimated_total[5m]))` vs `sum(rate(openclaw_tokens_input_total[5m]))`

The dashboard JSON will be approximately 400-600 lines. Use Mimir as the datasource (`"uid": "mimir"`).

- [ ] **Step 3: Add dashboard provisioning to Grafana tasks**

In `monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml`, add tasks to:
1. Create the dashboards provisioning directory
2. Copy the dashboards provider config
3. Copy the openclaw dashboard JSON

These should go after the existing datasources provisioning tasks.

```yaml
- name: Create dashboards provisioning directory
  ansible.builtin.file:
    path: "{{ grafana_data_dir }}/provisioning/dashboards"
    state: directory
    mode: "0755"

- name: Write dashboards provider config
  ansible.builtin.template:
    src: provisioning/dashboards.yml.j2
    dest: "{{ grafana_data_dir }}/provisioning/dashboards/dashboards.yml"
    mode: "0644"
  notify: Restart grafana-stack

- name: Copy OpenClaw dashboard
  ansible.builtin.copy:
    src: dashboards/openclaw.json
    dest: "{{ grafana_data_dir }}/provisioning/dashboards/openclaw.json"
    mode: "0644"
  notify: Restart grafana-stack
```

- [ ] **Step 4: Ensure Grafana mounts the dashboards directory**

Check `monitoring/grafana-stack-setup/roles/grafana-stack/templates/docker-compose.yml.j2`. The existing Grafana container mounts `./provisioning:/etc/grafana/provisioning:ro`. Since both `datasources.yml` and `dashboards/` live under `provisioning/`, the mount already covers dashboards. No change needed if the directory structure is `provisioning/dashboards/dashboards.yml` and `provisioning/dashboards/openclaw.json`.

Verify this is the case. If the existing template only mounts specific subdirs, add the dashboards mount.

- [ ] **Step 5: Commit**

```bash
git add monitoring/grafana-stack-setup/roles/grafana-stack/templates/provisioning/dashboards.yml.j2
git add monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json
git add monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml
git commit -m "feat(monitoring): add OpenClaw Grafana dashboard with provisioning

4-row dashboard: Overview, Provider Breakdown, Agent Activity, Operational.
Dashboard provider config enables auto-loading from provisioning dir."
```

---

### Task 6: Deploy and Verify End-to-End

This task runs on the live homelab. Not automatable in CI.

- [ ] **Step 1: Set openclaw_metrics_host in monitoring group_vars**

Edit `monitoring/grafana-stack-setup/group_vars/all.yml` and set:

```yaml
openclaw_metrics_host: "127.0.0.1"
```

Commit:
```bash
git add monitoring/grafana-stack-setup/group_vars/all.yml
git commit -m "chore: enable OpenClaw metrics scraping in monitoring config"
```

- [ ] **Step 2: Deploy OpenClaw stack**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook ai/openclaw-setup/setup.yml -e @/tmp/.openclaw-deploy-vars.json
```

Or manually build and start the metrics container:
```bash
cd /opt/openclaw
sudo docker compose build openclaw-metrics
sudo docker compose down && sudo docker compose up -d
```

- [ ] **Step 3: Verify metrics endpoint**

```bash
curl -s http://127.0.0.1:9101/metrics | grep "openclaw_"
```

Expected: Prometheus metrics with `openclaw_info`, token counters, etc.

- [ ] **Step 4: Deploy monitoring stack**

```bash
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/grafana-stack-setup/setup.yml
```

Or manually restart Alloy to pick up the new scrape config.

- [ ] **Step 5: Verify Alloy is scraping**

```bash
# Check Alloy targets
curl -s http://localhost:12345/api/v0/targets | grep openclaw
```

- [ ] **Step 6: Verify in Grafana**

Open `https://grafana.kamilandrzejrybacki.dpdns.org`:
1. Go to Explore → Mimir datasource
2. Query `openclaw_info` — should return 1 result
3. Go to Dashboards → find "OpenClaw LLM Metrics"
4. Verify panels show data (may need to send some messages via Telegram to generate traffic)

- [ ] **Step 7: Generate test traffic**

Send a few messages to the Telegram bot to generate token usage data. Wait 2 minutes for scrape cycle. Verify Grafana panels update.
