# OpenClaw Multi-Model Routing Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add complexity-tiered routing and named agents to OpenClaw so ~80-90% of traffic hits free models while complex tasks route to paid DeepSeek.

**Architecture:** Define tier fallback chains and agent definitions as Ansible variables in `defaults/main.yml`, render them into the existing `openclaw.json` config via the Jinja2 template. Tiers are conditionally filtered based on which providers have API keys configured. Agent definitions referencing empty tiers fall back to `agents.defaults.model`.

**Tech Stack:** Ansible, Jinja2 templates, JSON config

**Spec:** `docs/superpowers/specs/2026-03-23-openclaw-agents-design.md`

**Out of scope (follow-ups):**
- Cascading failure behavior (HTTP 503 vs escalation per tier) -- depends on OpenClaw supporting per-tier fallback policies
- Cost alerting via n8n workflow -- operational concern for after initial deployment
- Ollama in tier routing -- remains manual `/model local` only

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `ai/openclaw-setup/roles/openclaw/defaults/main.yml` | Modify | Add `openclaw_agent_tiers` and `openclaw_agent_definitions` variables |
| `ai/openclaw-setup/roles/openclaw/templates/config.yaml.j2` | Modify | Render tiers + definitions into `agents` block with conditional provider filtering |
| `ai/openclaw-setup/roles/openclaw/tasks/main.yml` | Modify | Update debug output to show agent routing info |

---

### Task 0: Verify OpenClaw Config Schema

Before writing any code, confirm OpenClaw supports `agents.tiers` and `agents.definitions` in its config.

- [ ] **Step 1: Check OpenClaw documentation or source**

```bash
# Check the OpenClaw docs or GitHub for config schema
docker exec openclaw openclaw --help 2>&1 | head -30
# Or check if there's a JSON schema reference in the existing config
ssh lw-main "docker exec openclaw cat /home/node/.openclaw/openclaw.json 2>/dev/null | python3 -m json.tool | head -5"
```

If `agents.tiers` and `agents.definitions` are **not** supported, stop and revisit the spec -- the routing logic would need to go through a different mechanism (e.g. the `routing` config section or external proxy).

- [ ] **Step 2: Test with a minimal config addition**

SSH into the host and add a test key to the running config to verify OpenClaw does not reject unknown keys:

```bash
ssh lw-main "docker exec openclaw openclaw doctor"
```

If OpenClaw validates strictly and rejects unknown keys, this plan needs revision.

---

### Task 1: Add Agent Variables to Defaults

**Files:**
- Modify: `ai/openclaw-setup/roles/openclaw/defaults/main.yml` (append after line 49)

- [ ] **Step 1: Add `openclaw_agent_tiers` variable**

Append after `openclaw_thinking_model` (line 49), before `# --- Security ---` (line 51):

```yaml
# --- Agent routing tiers ---
# Each tier defines a fallback chain of "provider/model" IDs and a timeout (seconds).
# Models whose provider API key is missing are filtered out at template render time.
openclaw_agent_tiers:
  simple:
    timeout: 10
    models:
      - "groq/llama-3.3-70b-versatile"
      - "nvidia/kimi-k2.5"
      - "google/gemini-2.5-flash"
  moderate:
    timeout: 30
    models:
      - "nvidia/kimi-k2.5"
      - "google/gemini-2.5-flash"
      - "deepseek/deepseek-chat"
  complex:
    timeout: 120
    models:
      - "deepseek/deepseek-chat"
      - "deepseek/deepseek-reasoner"
      - "google/gemini-2.5-flash"
```

- [ ] **Step 2: Add `openclaw_agent_definitions` variable**

Append directly after the tiers block:

```yaml
# --- Named agents ---
# Each agent maps to a tier for model routing and has a system prompt.
# If the referenced tier is empty (all providers missing), the agent
# falls back to agents.defaults.model.
openclaw_agent_definitions:
  quick-chat:
    tier: simple
    system_prompt: >-
      You are a concise assistant. Give direct answers without preamble or filler.
  code-helper:
    tier: moderate
    system_prompt: >-
      You are a code assistant focused on quality. Follow existing patterns in the
      codebase. Provide working code without over-engineering. Prefer immutable patterns.
  infra-ops:
    tier: moderate
    system_prompt: >-
      You are a homelab infrastructure assistant. The homelab has two nodes:
      lw-main (10.0.0.1) and lw-s1 (10.0.0.2). Services run in Docker with
      Caddy reverse proxy, Vault for secrets, and Pi-hole for DNS. Answer in
      terms of the actual stack.
  deep-coder:
    tier: complex
    system_prompt: >-
      You are a senior software engineer. Provide thorough reasoning with
      trade-off analysis. Produce complete, tested solutions. Consider
      architectural implications.
```

- [ ] **Step 3: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/defaults/main.yml
git commit -m "feat(openclaw): add agent tier and definition variables"
```

---

### Task 2: Render Tiers in Config Template

**Files:**
- Modify: `ai/openclaw-setup/roles/openclaw/templates/config.yaml.j2:1` (prepend) and `:66-70` (replace agents block)

The existing `agents` block (lines 66-70) is:

```json
  "agents": {
    "defaults": {
      "model": "{{ openclaw_primary_model }}"
    }
  },
```

- [ ] **Step 1: Add provider availability mapping at top of template**

Insert at the very top of `config.yaml.j2` (before line 1). This builds a dict of available provider prefixes used to filter tier model lists:

```jinja2
{#- Build a set of available provider prefixes for tier model filtering -#}
{%- set _providers = {} -%}
{%- if openclaw_nvidia_api_key | default('') | length > 0 -%}
  {%- set _ = _providers.update({'nvidia': true}) -%}
{%- endif -%}
{%- if openclaw_groq_api_key | default('') | length > 0 -%}
  {%- set _ = _providers.update({'groq': true}) -%}
{%- endif -%}
{%- if openclaw_gemini_api_key | default('') | length > 0 -%}
  {%- set _ = _providers.update({'google': true}) -%}
{%- endif -%}
{%- if openclaw_deepseek_api_key | default('') | length > 0 -%}
  {%- set _ = _providers.update({'deepseek': true}) -%}
{%- endif -%}
{%- if openclaw_ollama_enabled | default(false) -%}
  {%- set _ = _providers.update({'ollama': true}) -%}
{%- endif -%}
{#- Pre-filter tiers once: build a dict of tier_name -> filtered_models -#}
{%- set _filtered_tiers = {} -%}
{%- for tier_name, tier in openclaw_agent_tiers.items() -%}
  {%- set _models = [] -%}
  {%- for m in tier.models -%}
    {%- if m.split('/')[0] in _providers -%}
      {%- if _models.append(m) -%}{%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {%- if _models | length > 0 -%}
    {%- set _ = _filtered_tiers.update({tier_name: {'timeout': tier.timeout, 'models': _models}}) -%}
  {%- endif -%}
{%- endfor -%}
```

- [ ] **Step 2: Replace the `agents` block with tier-aware rendering**

Replace lines 66-70 with the following. Uses Jinja2 `joiner()` for clean comma handling and references the pre-filtered `_filtered_tiers` dict (no duplicate filtering):

```jinja2
  "agents": {
    "defaults": {
      "model": "{{ openclaw_primary_model }}"
    }{% if _filtered_tiers | length > 0 %},
    "tiers": {
{%- set tier_comma = joiner(',') -%}
{%- for tier_name, tier in _filtered_tiers.items() %}
{{ tier_comma() }}
      "{{ tier_name }}": {
        "timeout": {{ tier.timeout }},
        "models": [{{ tier.models | map('tojson') | join(', ') }}]
      }
{%- endfor %}
    }{% endif %}{#- Render agent definitions whose tier exists after filtering -#}
{%- set _active_agents = [] -%}
{%- for agent_name, agent in openclaw_agent_definitions.items() -%}
  {%- if agent.tier in _filtered_tiers -%}
    {%- if _active_agents.append(agent_name) -%}{%- endif -%}
  {%- endif -%}
{%- endfor -%}
{% if _active_agents | length > 0 %},
    "definitions": {
{%- set def_comma = joiner(',') -%}
{%- for agent_name, agent in openclaw_agent_definitions.items() -%}
{%- if agent_name in _active_agents %}
{{ def_comma() }}
      "{{ agent_name }}": {
        "tier": "{{ agent.tier }}",
        "system_prompt": {{ agent.system_prompt | tojson }}
      }
{%- endif -%}
{%- endfor %}
    }{% endif %}
  },
```

- [ ] **Step 3: Verify template renders valid JSON locally**

```bash
python3 -c "
from jinja2 import Environment
env = Environment()
with open('ai/openclaw-setup/roles/openclaw/templates/config.yaml.j2') as f:
    try:
        env.parse(f.read())
        print('Jinja2 template syntax: OK')
    except Exception as e:
        print(f'Jinja2 syntax error: {e}')
        import sys; sys.exit(1)
"
```

- [ ] **Step 4: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/templates/config.yaml.j2
git commit -m "feat(openclaw): render agent tiers and definitions in config template

Filters tier model lists based on configured provider API keys using a
pre-computed dict. Uses joiner() for clean JSON comma handling.
Agent definitions referencing empty tiers are omitted."
```

---

### Task 3: Update Debug Output

**Files:**
- Modify: `ai/openclaw-setup/roles/openclaw/tasks/main.yml:140-147`

- [ ] **Step 1: Replace the "Routing:" block with agent-aware output**

Replace lines 140-147 (the "Routing:" block including the heartbeat and complexity lines) with:

```yaml
      Agents:
      {% for agent_name, agent in openclaw_agent_definitions.items() %}
      {% if agent.tier in openclaw_agent_tiers %}
        {{ agent_name }} → tier:{{ agent.tier }} ({{ openclaw_agent_tiers[agent.tier].timeout }}s)
      {% endif %}
      {% endfor %}

      Tier routing (raw — filtered at deploy time by available API keys):
      {% for tier_name, tier in openclaw_agent_tiers.items() %}
        {{ tier_name }} ({{ tier.timeout }}s) → {{ tier.models | join(' → ') }}
      {% endfor %}
```

- [ ] **Step 2: Commit**

```bash
git add ai/openclaw-setup/roles/openclaw/tasks/main.yml
git commit -m "feat(openclaw): update debug output with agent and tier routing info"
```

---

### Task 4: End-to-End Verification

Runs after deployment to the live instance. Not automatable in CI.

- [ ] **Step 1: Deploy to the live instance**

```bash
cd /home/kamil-rybacki/Code/ansible
ansible-playbook ai/openclaw-setup/setup.yml
```

- [ ] **Step 2: Verify the generated config is valid JSON**

```bash
ssh lw-main "cat /opt/openclaw/openclaw-home/openclaw.json | python3 -m json.tool > /dev/null && echo 'JSON OK' || echo 'JSON INVALID'"
```

- [ ] **Step 3: Verify agents and tiers are in the config**

```bash
ssh lw-main "cat /opt/openclaw/openclaw-home/openclaw.json | python3 -c '
import json, sys
d = json.load(sys.stdin)
agents = d.get(\"agents\", {})
print(\"Tiers:\", list(agents.get(\"tiers\", {}).keys()))
print(\"Agents:\", list(agents.get(\"definitions\", {}).keys()))
'"
```

Expected output:
```
Tiers: ['simple', 'moderate', 'complex']
Agents: ['quick-chat', 'code-helper', 'infra-ops', 'deep-coder']
```

- [ ] **Step 4: Verify OpenClaw health**

```bash
ssh lw-main "docker exec openclaw curl -sf http://localhost:18789/health"
ssh lw-main "docker exec openclaw openclaw doctor"
```

- [ ] **Step 5: Run routing verification tests**

```bash
ssh lw-main "docker exec openclaw openclaw models list"
```

Send test prompts to each agent and verify via `openclaw stats usage --period 1d` that the correct models handle them.
