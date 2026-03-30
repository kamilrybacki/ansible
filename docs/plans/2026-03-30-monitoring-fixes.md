# Monitoring Dashboard Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 177 broken/empty dashboard panels across 19 Grafana dashboards by correcting metric label mismatches, enabling missing exporters, fixing scrape configs, and repairing broken data sources.

**Architecture:** Issues fall into five categories — (1) dashboard query bugs fixable with Grafana API, (2) scrape config gaps in Alloy (alloy-agent or grafana-stack Alloy), (3) exporter config bugs (wrong DSN, not deployed), (4) new exporters needed (snapraid), and (5) K8s monitoring helm values missing collectors. All Ansible changes run against live homelab and immediately take effect.

**Tech Stack:** Ansible, Grafana Alloy (systemd + Docker), Docker Compose, Grafana HTTP API (Python urllib), PostgreSQL, n8n, prometheus-community exporters, ArgoCD + Helm, kubectl

---

## Phase 1 — Dashboard Query Fixes (no infra changes)

### Task 1.1: Fix NAS Storage dashboard — instance label + smartctl metric names

**Context:** NAS Storage panels query `instance="10.0.1.2"` but node_exporter reports `instance="lw-nas"`. smartctl-exporter runs but only `smartctl_devices` (count) is present — device-level metrics (`smartctl_device_smart_healthy`, `smartctl_device_smartctl_exit_code`) don't exist until Task 3.2 fixes the exporter. SnapRAID metrics (`snapraid_*`) are queried but the exporter isn't deployed until Task 3.3. Fix the Disk I/O panel now; mark SMART and SnapRAID panels as fixed-in-place for Task 3.x.

**Files:**
- Modify: Grafana dashboard `nas-storage` via HTTP API

- [ ] **Step 1: Fix NAS Disk I/O instance label via Grafana API**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

def api(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(f'{BASE}{path}', data=data, method=method,
           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code

# Fetch current dashboard
dash_resp, _ = api('GET', '/api/dashboards/uid/nas-storage')
dash = dash_resp['dashboard']

# Fix NAS Disk I/O panel: instance="10.0.1.2" → instance="lw-nas"
for panel in dash.get('panels', []):
    for target in panel.get('targets', []):
        if 'expr' in target:
            target['expr'] = target['expr'].replace('instance="10.0.1.2"', 'instance="lw-nas"')

resp, code = api('POST', '/api/dashboards/db', {
    'dashboard': dash, 'folderUid': 'nas',
    'overwrite': True, 'message': 'fix: NAS Disk I/O instance label lw-nas'
})
print(f'[{code}] {resp.get("status", resp)}')
```

Run: `python3 /tmp/fix_nas_storage.py`
Expected: `[200] success`

- [ ] **Step 2: Verify fix in Mimir**

```bash
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('rate(node_disk_read_bytes_total{instance=\"lw-nas\"}[5m])')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'series — should be >= 1')
"
```

Expected: `2 series — should be >= 1` (one per disk device)

- [ ] **Step 3: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add -p   # nothing to add — dashboard change is live in Grafana, not in git
git commit --allow-empty -m "fix(dashboards): NAS Storage — instance label lw-nas (applied via API)"
```

---

### Task 1.2: Fix MySQL Exporter dashboard — $job variable default

**Context:** The community MySQL dashboard has a `$job` template variable whose default is a stale value from the original Grafana Cloud setup. The correct job label is `mariadb` (set by mysqld-exporter Alloy relabeling on lw-nas).

**Files:**
- Modify: Grafana dashboard `549c2bf8936f7767ea6ac47c47b00f2a` via HTTP API

- [ ] **Step 1: Patch $job variable default**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

def api(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(f'{BASE}{path}', data=data, method=method,
           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code

dash_resp, _ = api('GET', '/api/dashboards/uid/549c2bf8936f7767ea6ac47c47b00f2a')
dash = dash_resp['dashboard']

for var in dash.get('templating', {}).get('list', []):
    if var.get('name') == 'job':
        var['current'] = {'text': 'mariadb', 'value': 'mariadb'}
        var['query']   = 'mariadb'
        var['options'] = [{'text': 'mariadb', 'value': 'mariadb', 'selected': True}]

resp, code = api('POST', '/api/dashboards/db', {
    'dashboard': dash, 'folderUid': 'nas',
    'overwrite': True, 'message': 'fix: set $job default to mariadb'
})
print(f'[{code}] {resp.get("status", resp)}')
```

Run: `python3 /tmp/fix_mysql_job.py`
Expected: `[200] success`

- [ ] **Step 2: Verify — open MySQL dashboard in browser and confirm panels show data**

```bash
echo "Open: http://localhost:3000/d/549c2bf8936f7767ea6ac47c47b00f2a"
# QPS and Questions panels should now show rate() data from job="mariadb"
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('rate(mysql_global_status_questions_total{job=\"mariadb\"}[5m])')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'series — should be 1')
"
```

---

### Task 1.3: Delete old Kubernetes Monitoring Dashboard (795lPdFGk)

**Context:** This community dashboard (`uid=795lPdFGk`, "Kubernetes Monitoring Dashboard (kubelet Cadvisor, node-exporter)") is entirely broken — all 15 panels use a `$node` template variable format that doesn't match available metrics. It is superseded by the `k8s_views_*` dashboards.

**Files:**
- Delete: Grafana dashboard `795lPdFGk` via HTTP API

- [ ] **Step 1: Delete dashboard**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

req = urllib.request.Request(f'{BASE}/api/dashboards/uid/795lPdFGk',
      method='DELETE', headers={'Authorization': f'Bearer {TOKEN}'})
try:
    resp = urllib.request.urlopen(req)
    print(f'[{resp.status}]', json.loads(resp.read()))
except urllib.error.HTTPError as e:
    print(f'[{e.code}]', json.loads(e.read()))
```

Run: `python3 /tmp/delete_old_k8s_dash.py`
Expected: `[200] {'message': 'Dashboard 795lPdFGk deleted'}`

---

### Task 1.4: Fix Security Services dashboard — Authelia metric name

**Context:** `authelia_authentication_attempts_total` does not exist in this version of Authelia. The actual metric is `authelia_authn` (a counter with `type` label: `1fa`/`2fa`). The "Authelia Authentication Rate" panel needs its query updated.

**Files:**
- Modify: Grafana dashboard `security-services` via HTTP API

- [ ] **Step 1: Verify the correct metric shape**

```bash
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('{job=\"security\",service=\"authelia\",__name__=~\"authelia_authn.*\"}')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
results = d['data']['result']
for r in results[:5]:
    print(r['metric'])
"
```

Expected: metrics with labels like `{__name__="authelia_authn", success="true/false", type="1fa"}` (or similar)

- [ ] **Step 2: Update panel query to correct metric**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

def api(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(f'{BASE}{path}', data=data, method=method,
           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code

dash_resp, _ = api('GET', '/api/dashboards/uid/security-services')
dash = dash_resp['dashboard']

for panel in dash.get('panels', []):
    if panel.get('title') == 'Authelia Authentication Rate':
        for target in panel.get('targets', []):
            # authelia_authn has labels: type (1fa/2fa), success (true/false)
            target['expr']         = 'rate(authelia_authn[$__rate_interval])'
            target['legendFormat'] = '{{type}} success={{success}}'

resp, code = api('POST', '/api/dashboards/db', {
    'dashboard': dash, 'folderUid': 'security',
    'overwrite': True, 'message': 'fix: authelia metric name authelia_authn'
})
print(f'[{code}] {resp.get("status", resp)}')
```

Run: `python3 /tmp/fix_authelia_metric.py`
Expected: `[200] success`

---

### Task 1.5: Fix K8s Views dashboards — replace machine_cpu_cores

**Context:** `machine_cpu_cores` is not scraped by the k8s-monitoring chart. The equivalent available metric is `kube_node_status_allocatable{resource="cpu"}` from kube-state-metrics, which gives the allocatable CPU core count per node.

**Files:**
- Modify: Grafana dashboards `k8s_views_global`, `k8s_views_ns`, `k8s_views_nodes` via HTTP API

- [ ] **Step 1: Patch machine_cpu_cores → kube_node_status_allocatable in all three dashboards**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

def api(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(f'{BASE}{path}', data=data, method=method,
           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code

def patch_expr(expr):
    # machine_cpu_cores → sum of allocatable CPUs per node
    if 'machine_cpu_cores' in expr:
        expr = expr.replace(
            'machine_cpu_cores',
            'kube_node_status_allocatable{resource="cpu"}'
        )
    # machine_memory_bytes → kube_node_status_allocatable{resource="memory"}
    if 'machine_memory_bytes' in expr:
        expr = expr.replace(
            'machine_memory_bytes',
            'kube_node_status_allocatable{resource="memory"}'
        )
    return expr

folder_map = {
    'k8s_views_global':  'k8s',
    'k8s_views_ns':      'k8s',
    'k8s_views_nodes':   'k8s',
}

for uid, folder_uid in folder_map.items():
    dash_resp, _ = api('GET', f'/api/dashboards/uid/{uid}')
    dash = dash_resp['dashboard']
    changed = False
    for panel in dash.get('panels', []):
        for target in panel.get('targets', []):
            if 'expr' in target:
                new_expr = patch_expr(target['expr'])
                if new_expr != target['expr']:
                    target['expr'] = new_expr
                    changed = True
    if changed:
        resp, code = api('POST', '/api/dashboards/db', {
            'dashboard': dash, 'folderUid': folder_uid,
            'overwrite': True,
            'message': 'fix: replace machine_cpu_cores/memory_bytes with kube_node_status_allocatable'
        })
        print(f'[{code}] {uid}: {resp.get("status", resp)}')
    else:
        print(f'No change needed: {uid}')
```

Run: `python3 /tmp/fix_k8s_machine_cores.py`
Expected:
```
[200] k8s_views_global: success
[200] k8s_views_ns: success
[200] k8s_views_nodes: success
```

- [ ] **Step 2: Verify**

```bash
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('kube_node_status_allocatable{resource=\"cpu\"}')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
for r in d['data']['result']:
    print(r['metric'].get('node'), '→', r['value'][1], 'cores')
"
```

Expected: `lw-c1 → 8 cores` (or however many allocatable CPUs)

---

### Task 1.6: Fix Blackbox — enable SSL cert expiry probes (HTTPS)

**Context:** Probe URLs are configured as HTTP (`http://n8n.kamilandrzejrybacki.dpdns.org`) so `probe_ssl_earliest_cert_expiry` is never populated. Changing to HTTPS makes the Blackbox exporter also verify the TLS certificate and record its expiry.

**Files:**
- Modify: `monitoring/grafana-stack-setup/group_vars/all.yml` lines 59-61

- [ ] **Step 1: Update probe URLs to HTTPS**

Edit `monitoring/grafana-stack-setup/group_vars/all.yml`:

```yaml
# Before:
probe_n8n_url: "http://n8n.kamilandrzejrybacki.dpdns.org"
probe_paperless_url: "http://paperless.kamilandrzejrybacki.dpdns.org"
probe_netbox_url: "http://netbox.kamilandrzejrybacki.dpdns.org"

# After:
probe_n8n_url: "https://n8n.kamilandrzejrybacki.dpdns.org"
probe_paperless_url: "https://paperless.kamilandrzejrybacki.dpdns.org"
probe_netbox_url: "https://netbox.kamilandrzejrybacki.dpdns.org"
```

- [ ] **Step 2: Redeploy grafana-stack to regenerate Alloy config**

```bash
cd /home/kamil-rybacki/Code/ansible
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/grafana-stack-setup/setup.yml
```

Expected: Alloy container restarts with updated config containing `https://` probe URLs.

- [ ] **Step 3: Verify SSL metric appears within 2 minutes**

```bash
sleep 90
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('(probe_ssl_earliest_cert_expiry{job=\"blackbox\"} - time()) / 86400')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
for r in d['data']['result']:
    print(r['metric'].get('service'), '→', round(float(r['value'][1])), 'days remaining')
"
```

Expected: 3 lines (n8n, paperless, netbox) each showing > 0 days.

- [ ] **Step 4: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/grafana-stack-setup/group_vars/all.yml
git commit -m "fix(grafana-stack): use HTTPS probe URLs for SSL cert expiry metrics"
```

---

### Task 1.7: Fix Redis dashboard — rate query uses wrong window

**Context:** The Redis community dashboard "Total Commands / sec" panel uses `rate(redis_commands_total[...])` over a window derived from the dashboard time range. With a 60s scrape interval and the panel's default aggregation, the inner time window resolves to less than `2*scrape_interval` making rate() return no data. Fix by patching the panel to use `$__rate_interval` and aggregate by `cmd`.

**Files:**
- Modify: Grafana dashboard `e008bc3f-81a2-40f9-baf2-a33fd8dec7ec` via HTTP API

- [ ] **Step 1: Inspect and patch rate panels**

```python
import urllib.request, json

TOKEN = '<GRAFANA_SA_TOKEN>'
BASE  = 'http://localhost:3000'

def api(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(f'{BASE}{path}', data=data, method=method,
           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code

uid = 'e008bc3f-81a2-40f9-baf2-a33fd8dec7ec'
dash_resp, _ = api('GET', f'/api/dashboards/uid/{uid}')
dash = dash_resp['dashboard']

# Print all panel titles + queries so we can see what needs fixing
for panel in dash.get('panels', []):
    if panel.get('type') != 'row':
        for t in panel.get('targets', []):
            if 'redis_commands' in t.get('expr', ''):
                print(f'Panel [{panel["id"]}]: {panel["title"]}')
                print(f'  expr: {t["expr"]}')
```

Run: `python3 /tmp/check_redis.py` and note which panels use the problematic expressions.

- [ ] **Step 2: Patch the rate window in affected panels**

After observing the output from Step 1, update each affected target's `expr` to use `[$__rate_interval]` instead of the fixed or derived window. Example fix:

```python
# Inside the same script, after inspecting, apply patch:
for panel in dash.get('panels', []):
    for target in panel.get('targets', []):
        expr = target.get('expr', '')
        if 'redis_commands' in expr:
            import re
            # Replace any fixed range [Xs] or [${__range_s}s] with [$__rate_interval]
            target['expr'] = re.sub(r'\[\$__range\w*\]|\[\d+[smh]\]', '[$__rate_interval]', expr)

resp, code = api('POST', '/api/dashboards/db', {
    'dashboard': dash, 'folderUid': 'nas',
    'overwrite': True,
    'message': 'fix: redis rate queries use $__rate_interval'
})
print(f'[{code}] {resp.get("status", resp)}')
```

---

## Phase 2 — PostgreSQL Fixes

### Task 2.1: Fix postgres_exporter user — pg_up=0

**Context:** `pg_up=0` on lw-nas means the postgres_exporter container cannot connect to the PostgreSQL instance. The DSN is `postgresql://postgres_exporter:prom_exporter_2026@10.0.1.2:5432/postgres`. The `postgres_exporter` role and password stored in Vault match, but the user likely doesn't exist in the running `shared-postgres` container (a fresh deployment would need the user created). We need to create the user and grant it monitoring access.

**Files:**
- Create: `/tmp/create_pg_exporter_user.sql` (temp, run once)

- [ ] **Step 1: Create postgres_exporter user in shared-postgres**

```bash
EXPORTER_PASS='prom_exporter_2026'   # from Vault: secret/homelab/shared-postgres → exporter_password

ssh kamil@10.0.1.2 "docker exec -i shared-postgres psql -U postgres" << SQL
-- Create monitoring user if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    CREATE USER postgres_exporter WITH PASSWORD '${EXPORTER_PASS}' CONNECTION LIMIT 5;
  ELSE
    ALTER USER postgres_exporter WITH PASSWORD '${EXPORTER_PASS}';
  END IF;
END\$\$;

-- Grant required monitoring privileges
GRANT pg_monitor TO postgres_exporter;
GRANT CONNECT ON DATABASE postgres TO postgres_exporter;
SQL
```

- [ ] **Step 2: Restart postgres-exporter container to re-connect**

```bash
ssh kamil@10.0.1.2 "docker restart postgres-exporter"
sleep 10
ssh kamil@10.0.1.2 "curl -s http://localhost:9187/metrics | grep '^pg_up'"
```

Expected: `pg_up 1`

- [ ] **Step 3: Verify pg_stat_database metrics now flow to Mimir (wait 2 minutes for scrape)**

```bash
sleep 120
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('{job=\"postgres\",__name__=~\"pg_stat_database.*\"}')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
names = sorted(set(r['metric']['__name__'] for r in d['data']['result']))
print('pg metrics:', names[:8])
"
```

Expected: 8+ distinct `pg_stat_database_*` metric names.

---

### Task 2.2: Grant postgres_exporter access to n8n database (for Workflow Analytics)

**Context:** The Grafana `n8n-postgres` datasource connects as `postgres_exporter` user to the `n8n` database to run SQL against `workflow_entity` and `execution_entity` tables. This user needs `CONNECT` on the n8n database and `SELECT` on those tables.

**Files:**
- Create: `/tmp/grant_n8n_access.sql` (temp, run once)

- [ ] **Step 1: Grant access**

```bash
ssh kamil@10.0.1.2 "docker exec -i shared-postgres psql -U postgres" << SQL
-- Grant datasource user access to n8n database
GRANT CONNECT ON DATABASE n8n TO postgres_exporter;

-- Connect to n8n DB and grant SELECT on analytics tables
\c n8n
GRANT USAGE ON SCHEMA public TO postgres_exporter;
GRANT SELECT ON workflow_entity TO postgres_exporter;
GRANT SELECT ON execution_entity TO postgres_exporter;
GRANT SELECT ON credentials_entity TO postgres_exporter;
SQL
```

- [ ] **Step 2: Test connection from Grafana datasource**

```bash
python3 -c "
import urllib.request, json
TOKEN = '<GRAFANA_SA_TOKEN>'
req = urllib.request.Request('http://localhost:3000/api/datasources/uid/n8n-postgres/health',
    headers={'Authorization': f'Bearer {TOKEN}'})
resp = urllib.request.urlopen(req)
print(json.loads(resp.read()))
"
```

Expected: `{'message': 'Database Connection OK', 'status': 'OK'}`

- [ ] **Step 3: Verify n8n Workflow Analytics dashboard shows data**

Open `http://localhost:3000/d/adfcxfk` — "Total workflows" and "Total executions" stats should now show numbers.

---

## Phase 3 — n8n Prometheus Metrics

### Task 3.1: Enable n8n metrics endpoint

**Context:** n8n's Prometheus metrics endpoint is disabled by default. It requires the `N8N_METRICS=true` env var. The n8n container on lw-s1 runs via the vault-shim pattern. The env var must be injected into the shim's env file (not the docker-compose directly).

**Files:**
- Modify: `/opt/n8n/.env` on `lw-s1` (192.168.0.108) — add N8N_METRICS vars

- [ ] **Step 1: Add metrics env vars to n8n on lw-s1**

```bash
ssh kamil@192.168.0.108 "
grep -q N8N_METRICS /opt/n8n/.env 2>/dev/null || cat >> /opt/n8n/.env << 'EOF'
N8N_METRICS=true
N8N_METRICS_INCLUDE_MESSAGE_EVENT_BUS_METRICS=false
N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL=true
N8N_METRICS_INCLUDE_NODE_TYPE_LABEL=true
EOF
echo 'Added metrics env vars'
"
```

- [ ] **Step 2: Restart n8n to pick up the env**

```bash
ssh kamil@192.168.0.108 "cd /opt/n8n && docker compose up -d n8n"
sleep 15
ssh kamil@192.168.0.108 "curl -s http://localhost:5678/metrics 2>/dev/null | grep '^n8n_' | head -5"
```

Expected: lines like `n8n_version_info{...} 1` and `n8n_active_workflow_count ...`

---

### Task 3.2: Enable n8n scraping in Alloy on lw-s1

**Context:** The Alloy agent on lw-s1 has `n8n_metrics_enabled: false` (default). Re-running the alloy-agent setup with the flag enabled will add the scrape block and restart Alloy.

**Files:**
- Modify: `monitoring/alloy-agent-setup/group_vars/all.yml`

- [ ] **Step 1: Enable n8n metrics in alloy-agent defaults**

Edit `monitoring/alloy-agent-setup/group_vars/all.yml`:

```yaml
# Add/change:
n8n_metrics_enabled: true
n8n_metrics_port: 5678
```

- [ ] **Step 2: Re-run alloy-agent setup targeting only lw-s1**

```bash
cd /home/kamil-rybacki/Code/ansible
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/alloy-agent-setup/setup.yml
# When prompted:
# [1/4] IP addresses: 192.168.0.108
# [2/4] SSH user: kamil
# [3/4] Mimir host IP: 10.0.1.2
# [4/4] Loki host IP: 10.0.1.2
```

- [ ] **Step 3: Verify n8n metrics in Mimir (wait 2 minutes)**

```bash
sleep 120
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('{job=\"n8n\"}')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
names = sorted(set(r['metric']['__name__'] for r in d['data']['result']))
print(len(names), 'n8n metrics:', names[:5])
"
```

Expected: 10+ n8n metric names including `n8n_version_info`, `n8n_active_workflow_count`.

- [ ] **Step 4: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/alloy-agent-setup/group_vars/all.yml
git commit -m "feat(alloy-agent): enable n8n metrics scraping on lw-s1"
```

---

## Phase 4 — NAS Exporters

### Task 4.1: Fix smartctl-exporter — device-level metrics missing

**Context:** smartctl-exporter detects 2 devices (`smartctl_devices=2`) but no `smartctl_device_*` metrics are produced. The likely cause: the container's `prometheuscommunity/smartctl-exporter:v0.12.0` image bundles smartctl but the binary path may differ, OR the `--smartctl.path` flag needs to point to the host's smartctl via the `/dev` bind mount. Add explicit `--smartctl.path` and re-deploy.

**Files:**
- Modify: `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2`
- Modify: `monitoring/nas-monitoring-setup/roles/nas-monitoring/tasks/main.yml`

- [ ] **Step 1: Check what smartctl binary path exists in the container**

```bash
ssh kamil@10.0.1.2 "docker exec smartctl-exporter which smartctl 2>/dev/null || docker exec smartctl-exporter find / -name smartctl 2>/dev/null | head -3"
```

Note the path (expected: `/usr/sbin/smartctl` or `/usr/bin/smartctl`).

- [ ] **Step 2: Add explicit smartctl path and device rescan interval to docker-compose template**

Edit `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2`, update the `smartctl-exporter` service:

```yaml
  smartctl-exporter:
    image: {{ smartctl_exporter_image }}
    container_name: smartctl-exporter
    restart: {{ restart_policy }}
    privileged: true
    ports:
      - "127.0.0.1:{{ smartctl_exporter_port }}:9633"
    volumes:
      - /dev:/dev:ro
    command:
      - "--smartctl.path=/usr/sbin/smartctl"
      - "--smartctl.rescan-interval=5m"
```

- [ ] **Step 3: Re-deploy on lw-nas**

```bash
cd /home/kamil-rybacki/Code/ansible
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/nas-monitoring-setup/setup.yml
```

- [ ] **Step 4: Verify smartctl_device_smart_healthy appears**

```bash
ssh kamil@10.0.1.2 "curl -s http://localhost:9633/metrics | grep '^smartctl_device' | head -10"
```

Expected: lines like `smartctl_device_smart_healthy{device="/dev/sda",...} 1`

- [ ] **Step 5: Verify metrics flow to Mimir (wait 2 minutes)**

```bash
sleep 120
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('smartctl_device_smart_healthy')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'devices — should be >= 1')
"
```

- [ ] **Step 6: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2
git commit -m "fix(nas-monitoring): smartctl-exporter explicit binary path for device SMART metrics"
```

---

### Task 4.2: Add snapraid_exporter to NAS monitoring

**Context:** The NAS Storage dashboard queries `snapraid_sync_age_seconds`, `snapraid_scrub_age_seconds`, and `snapraid_disk_fail_probability` — but no snapraid exporter is deployed. We use `dr1010/snapraid-exporter` which reads SnapRAID status output via a textfile collector script, OR an HTTP exporter. Use `linuxserver/snapraid-exporter` Docker image which wraps `snapraid status`.

**Files:**
- Modify: `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2`
- Modify: `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/alloy.river.j2`
- Modify: `monitoring/nas-monitoring-setup/group_vars/all.yml`

- [ ] **Step 1: Add snapraid_exporter image and port to group_vars**

Edit `monitoring/nas-monitoring-setup/group_vars/all.yml`, add:

```yaml
snapraid_exporter_image: "lmintmate/snapraid-exporter:latest"
snapraid_exporter_port: 9669
```

- [ ] **Step 2: Add snapraid-exporter service to docker-compose template**

Edit `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2`, add after the `docker-exporter` service:

```yaml
  snapraid-exporter:
    image: {{ snapraid_exporter_image }}
    container_name: snapraid-exporter
    restart: {{ restart_policy }}
    privileged: true
    ports:
      - "127.0.0.1:{{ snapraid_exporter_port }}:9669"
    volumes:
      - /etc/snapraid.conf:/etc/snapraid.conf:ro
      - /mnt:/mnt:ro
```

- [ ] **Step 3: Add snapraid scrape block to NAS Alloy config template**

Edit `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/alloy.river.j2`, add after the smartctl block:

```
// ── SnapRAID status ──────────────────────────────────────────────────────────
prometheus.scrape "snapraid" {
  targets         = [{"__address__" = "localhost:{{ snapraid_exporter_port }}"}]
  metrics_path    = "/metrics"
  forward_to      = [prometheus.relabel.snapraid_labels.receiver]
  scrape_interval = "{{ alloy_scrape_interval }}"
}

prometheus.relabel "snapraid_labels" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  rule {
    target_label = "job"
    replacement  = "snapraid"
  }
  rule {
    target_label = "instance"
    replacement  = "{{ ansible_hostname | default('lw-nas') }}"
  }
}
```

- [ ] **Step 4: Re-deploy on lw-nas**

```bash
cd /home/kamil-rybacki/Code/ansible
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/nas-monitoring-setup/setup.yml
```

- [ ] **Step 5: Verify**

```bash
ssh kamil@10.0.1.2 "curl -s http://localhost:9669/metrics | grep '^snapraid_' | head -5"
```

Expected: `snapraid_sync_age_seconds`, `snapraid_scrub_age_seconds`, `snapraid_disk_fail_probability` metrics.

- [ ] **Step 6: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/docker-compose.yml.j2
git add monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/alloy.river.j2
git add monitoring/nas-monitoring-setup/group_vars/all.yml
git commit -m "feat(nas-monitoring): add snapraid_exporter for SnapRAID status metrics"
```

---

## Phase 5 — Optional node_exporter Collectors

### Task 5.1: Enable systemd and hwmon collectors in Alloy unix exporter

**Context:** The Alloy `prometheus.exporter.unix` block on all nodes uses default collectors, which omit `systemd` (systemd unit states) and `hwmon` (CPU temp, fan speed). These are needed for the "Hardware Temperature Monitor", "IRQ Detail", and "Systemd Units State" panels in Node Exporter Full dashboard. Note: hwmon data availability depends on the host having hardware sensors exposed via `/sys/class/hwmon`.

**Files:**
- Modify: `monitoring/alloy-agent-setup/roles/alloy-agent/templates/alloy.river.j2`

- [ ] **Step 1: Add enable_collectors to the unix exporter block**

Edit `monitoring/alloy-agent-setup/roles/alloy-agent/templates/alloy.river.j2`. Change:

```
// Before:
prometheus.exporter.unix "host" {}

// After:
prometheus.exporter.unix "host" {
  enable_collectors = ["cpu", "diskstats", "filesystem", "loadavg", "meminfo",
                       "netdev", "netstat", "stat", "time", "uname", "vmstat",
                       "systemd", "hwmon", "pressure", "processes", "interrupts"]
}
```

- [ ] **Step 2: Re-run alloy-agent setup on all three Docker-host nodes**

```bash
cd /home/kamil-rybacki/Code/ansible
sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/alloy-agent-setup/setup.yml
# [1/4] IP addresses: 192.168.0.105,192.168.0.108
# [2/4] SSH user: kamil
# [3/4] Mimir host IP: 10.0.1.2
# [4/4] Loki host IP: 10.0.1.2
```

Note: lw-nas uses a separate alloy (Docker container via nas-monitoring-setup, not the systemd alloy-agent). Update the NAS alloy template separately:

Edit `monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/alloy.river.j2`. Change:

```
// Before:
prometheus.exporter.unix "host" {
  procfs_path          = "/host/proc"
  sysfs_path           = "/host/sys"
  textfile {
    directory = "/textfile"
  }
}

// After:
prometheus.exporter.unix "host" {
  procfs_path          = "/host/proc"
  sysfs_path           = "/host/sys"
  enable_collectors    = ["cpu", "diskstats", "filesystem", "loadavg", "meminfo",
                          "netdev", "netstat", "stat", "time", "uname", "vmstat",
                          "systemd", "hwmon", "pressure", "processes", "interrupts"]
  textfile {
    directory = "/textfile"
  }
}
```

Then: `sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/nas-monitoring-setup/setup.yml`

- [ ] **Step 3: Verify systemd metrics appear**

```bash
sleep 90
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('node_systemd_unit_state{name=~\"docker.service\"}')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'systemd series — should be > 0')
"
```

Expected: `> 0 systemd series`

- [ ] **Step 4: Commit**

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/alloy-agent-setup/roles/alloy-agent/templates/alloy.river.j2
git add monitoring/nas-monitoring-setup/roles/nas-monitoring/templates/alloy.river.j2
git commit -m "feat(alloy): enable systemd + hwmon collectors in node_exporter"
```

---

## Phase 6 — Kubernetes Monitoring Fixes

### Task 6.1: Add missing kube-state-metrics collectors to k8s-monitoring

**Context:** The k8s-monitoring ArgoCD app uses default kube-state-metrics resource collectors but several are disabled or missing. Missing: `namespace`, `pod` (partial — `qos_class`, `container_status` fields absent), `service`, `endpoint`, `ingress`, `configmap`, `secret`, `deployment`/`daemonset`/`statefulset` label metrics. These are needed by the K8s Views dashboards. The k8s-monitoring v1.x chart passes configuration via ArgoCD helm parameters.

**Files:**
- Modify: `/tmp/argocd-app-k8s-monitoring.yml` (source of truth for the ArgoCD app manifest)

- [ ] **Step 1: Check what kube-state-metrics already collects**

```bash
KUBECONFIG=~/.kube/lw-c1.yaml kubectl get deployment -n monitoring -l app.kubernetes.io/name=kube-state-metrics -o yaml | grep -A5 "args:"
```

Note which `--resources` flags are present (if any).

- [ ] **Step 2: Update ArgoCD app to enable full kube-state-metrics collector set**

The k8s-monitoring chart uses the sub-chart `kube-state-metrics`. We need to pass through helm values. Switch the ArgoCD app to use `valuesObject` instead of flat `parameters` for the kube-state-metrics config.

Edit `/tmp/argocd-app-k8s-monitoring.yml` — add a `helm.valuesObject` section alongside existing parameters:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: k8s-monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    targetRevision: "~1.0"
    chart: k8s-monitoring
    helm:
      parameters:
        - name: "cluster.name"
          value: "lw-c1"
        - name: "externalServices.prometheus.host"
          value: "http://10.0.1.2:9009"
        - name: "externalServices.prometheus.writeEndpoint"
          value: "/api/v1/push"
        - name: "externalServices.loki.host"
          value: "http://10.0.1.2:3100"
        - name: "externalServices.loki.writeEndpoint"
          value: "/loki/api/v1/push"
        - name: "metrics.enabled"
          value: "true"
        - name: "metrics.node-exporter.enabled"
          value: "true"
        - name: "metrics.kube-state-metrics.enabled"
          value: "true"
        - name: "metrics.kubelet.enabled"
          value: "true"
        - name: "metrics.apiserver.enabled"
          value: "true"
        - name: "logs.enabled"
          value: "true"
        - name: "logs.pod_logs.enabled"
          value: "true"
        - name: "opencost.enabled"
          value: "false"
        - name: "prometheus-operator-crds.enabled"
          value: "false"
      valuesObject:
        kube-state-metrics:
          collectors:
            - certificatesigningrequests
            - configmaps
            - cronjobs
            - daemonsets
            - deployments
            - endpoints
            - horizontalpodautoscalers
            - ingresses
            - jobs
            - leases
            - limitranges
            - mutatingwebhookconfigurations
            - namespaces
            - networkpolicies
            - nodes
            - persistentvolumeclaims
            - persistentvolumes
            - poddisruptionbudgets
            - pods
            - replicasets
            - replicationcontrollers
            - resourcequotas
            - secrets
            - services
            - statefulsets
            - storageclasses
            - validatingwebhookconfigurations
            - volumeattachments
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 3: Apply and sync**

```bash
KUBECONFIG=~/.kube/lw-c1.yaml kubectl apply -f /tmp/argocd-app-k8s-monitoring.yml
sleep 30
KUBECONFIG=~/.kube/lw-c1.yaml kubectl get application k8s-monitoring -n argocd \
  -o jsonpath='{.status.sync.status} {.status.health.status}'
```

Expected: `Synced Healthy`

- [ ] **Step 4: Verify namespace metrics appear in Mimir**

```bash
sleep 120
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('kube_namespace_created')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'namespaces — should be > 0')
"
```

Expected: `> 5 namespaces`

---

### Task 6.2: Enable cAdvisor throttling and OOM metrics

**Context:** `container_cpu_cfs_throttled_seconds_total`, `container_oom_events_total` are cAdvisor metrics scraped via kubelet but blocked by the k8s-monitoring chart's default metric allowlist. Add these to the allowed metrics list via helm values.

**Files:**
- Modify: `/tmp/argocd-app-k8s-monitoring.yml`

- [ ] **Step 1: Extend valuesObject with kubelet metric allowlist additions**

In `/tmp/argocd-app-k8s-monitoring.yml`, extend the `valuesObject` section:

```yaml
      valuesObject:
        kube-state-metrics:
          # ... (existing collectors list from Task 6.1) ...
        metrics:
          kubelet:
            extraMetricRelabelingRules: |
              - source_labels: [__name__]
                regex: 'container_cpu_cfs_throttled.*|container_oom_events_total|container_memory_working_set_bytes'
                action: keep
```

- [ ] **Step 2: Apply and verify**

```bash
KUBECONFIG=~/.kube/lw-c1.yaml kubectl apply -f /tmp/argocd-app-k8s-monitoring.yml
sleep 120
python3 -c "
import urllib.request, json, urllib.parse
q = urllib.parse.quote('container_oom_events_total')
req = urllib.request.Request(f'http://10.0.1.2:9009/prometheus/api/v1/query?query={q}')
d = json.loads(urllib.request.urlopen(req).read())
print(len(d['data']['result']), 'oom series — should be >= 0 (metric exists)')
"
```

---

### Task 6.3: Add Portkey metrics scraping via pod annotations

**Context:** The Portkey Gateway (JS-based) does not expose a Prometheus `/metrics` endpoint by default in the open-source version. Before adding scraping, verify whether the endpoint exists. If it does: add pod annotations and ServiceMonitor. If it does not: remove the Portkey Gateway Grafana dashboard (it has no data and never will).

**Files:**
- Check: portkey pod annotations

- [ ] **Step 1: Test if portkey-free pod has a metrics endpoint**

```bash
KUBECONFIG=~/.kube/lw-c1.yaml kubectl exec -n portkey \
  $(kubectl --kubeconfig ~/.kube/lw-c1.yaml get pod -n portkey -l app=portkey-free -o name | head -1) \
  -- wget -qO- http://localhost:9464/metrics 2>/dev/null | head -5 || echo "No metrics endpoint found"
# Also try /metrics on the service port
KUBECONFIG=~/.kube/lw-c1.yaml kubectl exec -n portkey \
  $(kubectl --kubeconfig ~/.kube/lw-c1.yaml get pod -n portkey -l app=portkey-free -o name | head -1) \
  -- wget -qO- http://localhost:8787/metrics 2>/dev/null | head -5 || echo "No metrics on 8787"
```

- [ ] **Step 2a (if metrics exist): Add scraping annotations in portkey Helm chart**

Edit `/home/kamil-rybacki/Code/helm/charts/portkey/templates/deployment-free.yaml` — add to `spec.template.metadata.annotations`:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<METRICS_PORT>"
  prometheus.io/path: "/metrics"
```

Then commit and push to trigger ArgoCD sync:
```bash
cd /home/kamil-rybacki/Code/helm
git add charts/portkey/templates/deployment-free.yaml
git commit -m "feat(portkey): add prometheus scrape annotations"
git push
```

- [ ] **Step 2b (if no metrics endpoint): Delete Portkey Gateway dashboard**

```bash
python3 -c "
import urllib.request
TOKEN = '<GRAFANA_SA_TOKEN>'
req = urllib.request.Request('http://localhost:3000/api/dashboards/uid/portkey-gateway',
    method='DELETE', headers={'Authorization': f'Bearer {TOKEN}'})
import json
try:
    resp = urllib.request.urlopen(req)
    print(json.loads(resp.read()))
except urllib.error.HTTPError as e:
    print(json.loads(e.read()))
"
```

---

## Phase 7 — OpenClaw Metrics

### Task 7.1: Deploy openclaw-metrics exporter or fix container

**Context:** The grafana-stack Alloy is configured to scrape `openclaw-metrics:9101` (container name `openclaw-metrics` on the `homelab-net` Docker network), but `up=0` means no container with that name exists. OpenClaw is an agent orchestration framework — if it's actively in use, its metrics container needs to be deployed. If OpenClaw isn't actively deployed, delete the OpenClaw Agents dashboard.

**Files:**
- Check: Docker containers on lw-main for openclaw
- Potentially modify: `monitoring/grafana-stack-setup/group_vars/all.yml`

- [ ] **Step 1: Check if any OpenClaw container is running on lw-main**

```bash
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i openclaw
# Also check if openclaw is running under a different name
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i "agent\|llm"
```

- [ ] **Step 2a (if OpenClaw is deployed): Find the metrics port and fix the container name in grafana-stack group_vars**

```bash
# Find the actual container name and port
docker inspect <openclaw_container_name> --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{.Config.ExposedPorts}}'
```

Edit `monitoring/grafana-stack-setup/group_vars/all.yml`:
```yaml
openclaw_metrics_host: "<correct_container_name>"  # e.g., "openclaw" or "openclaw-agent"
openclaw_metrics_port: <correct_port>               # e.g., 9101
```

Then: `sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/grafana-stack-setup/setup.yml`

- [ ] **Step 2b (if OpenClaw is not deployed): Delete OpenClaw dashboards and disable scraping**

```bash
# Delete dashboards
python3 -c "
import urllib.request, json
TOKEN = '<GRAFANA_SA_TOKEN>'
for uid in ['openclaw-agents']:
    req = urllib.request.Request(f'http://localhost:3000/api/dashboards/uid/{uid}',
        method='DELETE', headers={'Authorization': f'Bearer {TOKEN}'})
    try:
        resp = urllib.request.urlopen(req)
        print(uid, json.loads(resp.read()))
    except urllib.error.HTTPError as e:
        print(uid, json.loads(e.read()))
"

# Disable openclaw scraping in group_vars
# Edit monitoring/grafana-stack-setup/group_vars/all.yml:
# openclaw_metrics_host: ""   # disabled — container not deployed
```

Then: `sudo HOME=/home/kamil-rybacki ansible-playbook monitoring/grafana-stack-setup/setup.yml`

```bash
cd /home/kamil-rybacki/Code/ansible
git add monitoring/grafana-stack-setup/group_vars/all.yml
git commit -m "fix(grafana-stack): disable openclaw metrics scrape — container not deployed"
```

---

## Phase 8 — Final Verification

### Task 8.1: Run full dashboard data audit

After all tasks are complete, re-run the data audit to confirm improvement.

- [ ] **Step 1: Run verification query against Mimir for all fixed metrics**

```bash
python3 << 'PYEOF'
import urllib.request, json, urllib.parse

BASE = 'http://10.0.1.2:9009/prometheus'

checks = [
    ("probe_ssl_earliest_cert_expiry", "SSL cert expiry (Task 1.6)"),
    ("n8n_version_info",               "n8n metrics (Task 3.2)"),
    ("pg_stat_database_tup_fetched",   "pg_exporter extended (Task 2.1)"),
    ("smartctl_device_smart_healthy",  "smartctl device metrics (Task 4.1)"),
    ("snapraid_sync_age_seconds",       "snapraid (Task 4.2)"),
    ("node_systemd_unit_state",         "systemd collector (Task 5.1)"),
    ("kube_namespace_created",          "kube-state-metrics namespaces (Task 6.1)"),
    ("container_oom_events_total",      "cAdvisor oom (Task 6.2)"),
    ("authelia_authn",                  "authelia metrics (already working)"),
]

for metric, label in checks:
    q = urllib.parse.quote(f'{metric}')
    req = urllib.request.Request(f'{BASE}/api/v1/query?query={q}')
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=5).read())
        n = len(d['data']['result'])
        status = "✅" if n > 0 else "❌"
        print(f"{status} {label}: {n} series")
    except Exception as e:
        print(f"❌ {label}: ERROR {e}")
PYEOF
```

Expected: all `✅` except any where the underlying service is legitimately absent (e.g., Portkey if it has no metrics endpoint).

- [ ] **Step 2: Commit any remaining changes**

```bash
cd /home/kamil-rybacki/Code/ansible
git status
# Add and commit any uncommitted files
git add -A
git commit -m "chore: monitoring fixes — all phases complete" || echo "nothing to commit"
```
