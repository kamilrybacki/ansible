# OpenClaw Metrics Exporter for Grafana

## Goal

Monitor OpenClaw's LLM usage via Grafana dashboards: token counts (in/out), cost per provider over time, request latency, error rates, agent activity, cache efficiency, and cost burn rate projections. Data flows from a custom Python Prometheus exporter into the existing Mimir → Grafana stack via Alloy.

## Architecture

A Python Docker container (`openclaw-metrics`) runs alongside OpenClaw in the same docker-compose. It reads OpenClaw session JSONL files and gateway structured logs via read-only bind mounts, exposes Prometheus metrics on port 9101, and is scraped by Alloy every 60 seconds into Mimir.

```
OpenClaw container
  ├── /home/node/.openclaw/  (bind mount: ./openclaw-home)
  │   └── agents/*/sessions/*.jsonl   ← SessionWatcher (watchdog inotify)
  └── /tmp/openclaw/*.log             ← LogTailer (shared via named volume)
                    │
                    ▼
         openclaw-metrics:9101/metrics
                    │
                    ▼
         Alloy (60s scrape via host IP) → Mimir → Grafana
```

### Data Sources

1. **Session JSONL files** (`~/.openclaw/agents/*/sessions/*.jsonl`) — Per-message usage structs with `input`/`output`/`cacheRead`/`cacheWrite` token counts and `cost` breakdowns. Shared via bind mount (`./openclaw-home:/data/openclaw-home:ro`). Watched via `watchdog` inotify — works reliably on bind mounts on the same host.
2. **Gateway structured logs** (`/tmp/openclaw/*.log`) — JSON log entries with agent run events (`embedded_run_agent_end`), errors, provider info, failover decisions. Shared via a named Docker volume (`openclaw-logs`) mounted in both the OpenClaw container and the metrics exporter.

### Token Estimation

When providers report 0 tokens (NVIDIA NIM, Groq free tier):
- **Input tokens**: character count of user message + system prompt, divided by 4
- **Output tokens**: character count of assistant response, divided by 4
- Estimation fires only when provider returns exactly 0 for both input and output
- If partial data reported (e.g. output but not input), only estimate the missing field
- Estimated tokens counted in both the main counter AND a separate `openclaw_tokens_estimated_total` counter for transparency
- **Limitation**: The 4 chars/token heuristic is calibrated for English text with GPT-style tokenizers. Code-heavy or non-English prompts may be off by 2-3x. Dashboards should note this.

### Counter Restart Behavior

On startup, the exporter scans all existing session JSONL files to initialize counters. On crash/restart, it re-scans and re-adds all historical data, causing a counter jump. Prometheus handles this correctly via `rate()` counter-reset detection. This is by design — no persistence layer needed.

## Metrics Catalog

All metrics prefixed with `openclaw_`.

### Essential (tokens + cost + requests)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `openclaw_tokens_input_total` | Counter | `provider`, `model`, `agent` | Input tokens sent to providers |
| `openclaw_tokens_output_total` | Counter | `provider`, `model`, `agent` | Output tokens received from providers |
| `openclaw_cost_dollars_total` | Counter | `provider`, `model`, `agent` | Cumulative cost in USD |
| `openclaw_requests_total` | Counter | `provider`, `model`, `agent`, `status` | Requests per provider (status: success/error) |

### Operational

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `openclaw_request_duration_seconds` | Histogram | `provider`, `model` | Response latency (buckets: 0.5, 1, 5, 10, 30, 60, 120, 300s) |
| `openclaw_errors_total` | Counter | `provider`, `error_type` | Errors by type (rate_limit, auth, timeout, model_not_found) |
| `openclaw_active_sessions` | Gauge | `agent` | Currently active session count |
| `openclaw_channel_requests_total` | Counter | `agent`, `channel` | Requests per agent and channel (telegram, webchat) |

### Full Observability

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `openclaw_tokens_cache_read_total` | Counter | `provider`, `model` | Cache read tokens |
| `openclaw_tokens_cache_write_total` | Counter | `provider`, `model` | Cache write tokens |
| `openclaw_tokens_estimated_total` | Counter | `provider`, `model` | Tokens from best-effort estimation |
| `openclaw_telegram_messages_total` | Counter | `direction` | Telegram messages in/out |
| `openclaw_ollama_inference_seconds` | Histogram | `model` | Local Ollama inference time |
| `openclaw_heartbeat_status` | Gauge | | 1=healthy, 0=failed |
| `openclaw_cost_rate_dollars_per_hour` | Gauge | `provider` | Rolling 1h cost burn rate |
| `openclaw_info` | Gauge (always 1) | `version`, `primary_model` | Instance metadata |

## Integration

### Alloy Scrape Config

Added to the central Alloy config template (`alloy.river.j2`), conditional on `openclaw_metrics_host` being set (following the LibreNMS pattern of using a host variable):

```river
{% if openclaw_metrics_host | default('') | length > 0 %}
prometheus.scrape "openclaw" {
  targets = [{"__address__" = "{{ openclaw_metrics_host }}:{{ openclaw_metrics_port }}"}]
  metrics_path = "/metrics"
  forward_to = [prometheus.relabel.openclaw_labels.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "openclaw_labels" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  rule {
    target_label = "job"
    replacement = "openclaw"
  }
  rule {
    target_label = "instance"
    replacement = "{{ openclaw_metrics_host }}"
  }
}
{% endif %}
```

**Cross-role variable**: `openclaw_metrics_host` and `openclaw_metrics_port` are set in the monitoring stack's `group_vars/all.yml` (or the playbook's inventory), not in the OpenClaw role. Both playbooks run against the same Node 1 host, so shared `group_vars` work. Default: `openclaw_metrics_host: ""` (disabled) in monitoring defaults. Set to `"127.0.0.1"` when OpenClaw metrics are deployed.

### Network & Port Strategy

The `openclaw-metrics` container exposes port 9101 on the host loopback only (`127.0.0.1:9101:9101`). Alloy scrapes via `127.0.0.1:9101` (same host). No Docker cross-network resolution needed — same pattern as LibreNMS (`{{ librenms_scrape_host }}:{{ librenms_scrape_port }}`).

The container still joins `openclaw-net` for access to the shared `openclaw-logs` named volume.

### Gateway Log Volume

OpenClaw writes logs to `/tmp/openclaw/` inside its container. A named Docker volume `openclaw-logs` is mounted at `/tmp/openclaw` in the OpenClaw container and at `/data/openclaw-logs:ro` in the metrics exporter:

```yaml
volumes:
  openclaw-logs:

services:
  openclaw:
    volumes:
      - openclaw-logs:/tmp/openclaw
      # ... existing mounts
  openclaw-metrics:
    volumes:
      - ./openclaw-home:/data/openclaw-home:ro
      - openclaw-logs:/data/openclaw-logs:ro
```

### Grafana Dashboard

Provisioned JSON dashboard with 4 rows:

1. **Overview** — Total tokens today, total cost today, requests/min, active sessions (stat panels)
2. **Provider Breakdown** — Cost per provider (stacked area), requests per provider (bar), error rate per provider (time series)
3. **Agent Activity** — Requests per agent (pie chart), model usage distribution, Telegram message throughput
4. **Operational** — Response latency p50/p95/p99 (time series), cache hit ratio (gauge), heartbeat status (stat), Ollama inference time (histogram), cost burn rate projection (stat + time series)

**Dashboard provisioning**: The dashboard JSON lives in the Grafana stack role (`monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json`), not the OpenClaw role. A `provisioning/dashboards/dashboards.yml` provider config is added to tell Grafana to scan the dashboards directory. This avoids cross-role dependencies.

## Ansible Changes

### New Files

| File | Purpose |
|------|---------|
| `roles/openclaw/files/openclaw-metrics/exporter.py` | Python exporter (plain `.py`, config via env vars) |
| `roles/openclaw/files/openclaw-metrics/Dockerfile` | Minimal Python 3.12-slim container |
| `roles/openclaw/files/openclaw-metrics/requirements.txt` | `prometheus_client`, `watchdog` |
| `monitoring/grafana-stack-setup/roles/grafana-stack/files/dashboards/openclaw.json` | Provisioned Grafana dashboard |
| `monitoring/grafana-stack-setup/roles/grafana-stack/templates/provisioning/dashboards.yml.j2` | Dashboard provisioning provider config |

### Modified Files

| File | Change |
|------|--------|
| `roles/openclaw/templates/docker-compose.yml.j2` | Add `openclaw-metrics` service + `openclaw-logs` named volume |
| `roles/openclaw/defaults/main.yml` | Add `openclaw_metrics_enabled: true`, `openclaw_metrics_port: 9101` |
| `roles/openclaw/tasks/main.yml` | Copy exporter files, build metrics container |
| `monitoring/grafana-stack-setup/roles/grafana-stack/templates/alloy.river.j2` | Add conditional `openclaw` scrape block |
| `monitoring/grafana-stack-setup/roles/grafana-stack/defaults/main.yml` | Add `openclaw_metrics_host`, `openclaw_metrics_port` |
| `monitoring/grafana-stack-setup/roles/grafana-stack/tasks/main.yml` | Add dashboard provisioning directory + config |

### Docker Compose Addition

```yaml
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

volumes:
  openclaw-logs:
```

### Defaults

```yaml
openclaw_metrics_enabled: true
openclaw_metrics_port: 9101
```

## Exporter Design

### Components

1. **SessionWatcher** — Uses `watchdog` to monitor `agents/*/sessions/*.jsonl` for new lines. Parses usage structs, updates counters. Handles token estimation.
2. **LogTailer** — Tails gateway log files. Parses JSON entries for `embedded_run_agent_end` events (latency, errors, provider, model), `telegram` events (message counts), `heartbeat` events (health status). Handles log rotation via inode tracking (OpenClaw uses date-based log files like `openclaw-2026-03-24.log`, so rotation is new-file-per-day, not truncation).
3. **MetricsServer** — `prometheus_client` HTTP server on port 9101. Exposes all registered metrics. Config via env vars (no Jinja2 templating needed).
4. **BurnRateCalculator** — Sliding 1-hour window over cost data. Updates `openclaw_cost_rate_dollars_per_hour` gauge every 60 seconds.

### Startup Flow

1. Scan all existing session JSONL files to initialize counters (catch up on historical data)
2. Start `watchdog` observer for new session file events
3. Start log tailer for gateway logs
4. Start Prometheus HTTP server on port 9101
5. Start burn rate calculator periodic task

### Error Handling

- Malformed JSONL lines: skip and log warning
- Missing session directories: retry on next watchdog event
- Log file rotation: OpenClaw creates new daily log files (`openclaw-YYYY-MM-DD.log`), tailer detects new files and starts tailing them
- Exporter crash: Docker `restart: unless-stopped` auto-recovers; counter re-initialization from full scan on startup
