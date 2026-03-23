# OpenClaw Multi-Model Routing Agents

## Goal

Configure OpenClaw with named agents and complexity-tiered routing to achieve ~80-90% free-model traffic while maintaining quality for coding, homelab ops, and automated pipeline workloads. Target monthly cost: $0-5.

## Prerequisite

The `agents` block in `openclaw.json` currently only supports `defaults.model`. Before implementation, verify that OpenClaw supports `agents.tiers` and `agents.definitions` keys by checking the OpenClaw documentation or source. If unsupported, the tier/fallback logic must be implemented differently (e.g. via the `routing` config section or an external proxy layer).

## Complexity Tiers

Three tiers handle model selection and failover. When a model returns HTTP 429 (rate limit) or times out, the request cascades to the next model in the chain.

| Tier | Primary | Fallback 1 | Fallback 2 | Timeout | Use Case |
|------|---------|------------|------------|---------|----------|
| `simple` | `groq/llama-3.3-70b-versatile` | `nvidia/kimi-k2.5` | `google/gemini-2.5-flash` | 10s | Short chat, lookups, simple formatting, status checks |
| `moderate` | `nvidia/kimi-k2.5` | `google/gemini-2.5-flash` | `deepseek/deepseek-chat` | 30s | Single-file code edits, infra queries, template generation |
| `complex` | `deepseek/deepseek-chat` | `deepseek/deepseek-reasoner` | `google/gemini-2.5-flash` | 120s | Multi-file code changes, architectural decisions, long-context analysis |

Model IDs use the `provider/model` qualified format matching the existing config template structure.

### Rationale

- `simple` starts with Groq for lowest latency on quick hits
- `moderate` uses NVIDIA Kimi K2.5 for good quality at 128k context, covering most code tasks
- `complex` goes straight to paid DeepSeek where quality matters most
- Gemini Flash (1M context, 1500 req/day free) serves as the universal safety net across all tiers
- Ollama (when enabled) remains a manual `/model local` selection only -- excluded from tier routing since local inference latency/quality varies by hardware

### Rate Limits Per Provider

| Provider | RPM | Daily Cap | Cost |
|----------|-----|-----------|------|
| NVIDIA NIM | 40 | None | Free |
| Groq | 30 | None | Free |
| Google Gemini | 15 | 1500 req | Free |
| DeepSeek Chat V3 | 60 | None | $0.27/$1.10 per 1M tokens (input/output) |
| DeepSeek Reasoner R1 | 60 | None | $0.55/$2.20 per 1M tokens (input/output) |

**Gemini daily cap risk:** At 15 RPM, the 1500 req/day quota exhausts in ~100 minutes of sustained use. Since Gemini is the safety-net fallback across all tiers, heavy days could exhaust it. See "Cascading Failure Mitigation" below.

### Cascading Failure Mitigation

If all free providers in a tier are rate-limited or unavailable simultaneously:

1. **`simple` tier exhausted** (Groq + NVIDIA + Gemini all down): return HTTP 503 with `Retry-After` header to the caller. Do not silently escalate to paid DeepSeek for simple queries -- the cost is not justified.
2. **`moderate` tier exhausted** (NVIDIA + Gemini down, DeepSeek still available): allow fallback to DeepSeek as designed -- moderate tasks justify the cost.
3. **`complex` tier exhausted** (DeepSeek + Gemini all down): return HTTP 503. This scenario requires both DeepSeek (paid, 60 RPM) and Gemini to be down, which is unlikely.
4. **Gemini daily quota exhausted**: tiers lose their safety net but primary/first-fallback models remain available. No action needed unless primaries also fail.

**Rollback:** If the new agent config breaks OpenClaw, revert the Ansible template changes and re-run the playbook. The previous `agents.defaults.model` config is restored automatically.

## Named Agents

### `quick-chat` (tier: simple)

- **Purpose:** General Q&A, summaries, quick lookups, casual conversation
- **System prompt:** Concise, direct answers. No preamble or filler.
- **Expected traffic share:** ~30%

### `code-helper` (tier: moderate)

- **Purpose:** Single-file code edits, code review, debugging, explaining code, generating snippets
- **System prompt:** Focused on code quality. Follow existing patterns in the codebase. Provide working code without over-engineering. Prefer immutable patterns.
- **Expected traffic share:** ~35%

### `infra-ops` (tier: moderate)

- **Purpose:** Homelab infrastructure queries -- Ansible playbook help, Docker troubleshooting, Netbox lookups, networking questions
- **System prompt:** Knows the homelab context: two nodes (lw-main 10.0.0.1, lw-s1 10.0.0.2), Docker-based services, Caddy reverse proxy, Vault for secrets, Pi-hole DNS. Answer in terms of the actual stack.
- **Expected traffic share:** ~20%

### `deep-coder` (tier: complex)

- **Purpose:** Multi-file refactoring, architectural decisions, long-context analysis, complex pipeline logic
- **System prompt:** Thorough reasoning with trade-off analysis. Produce complete, tested solutions. Used sparingly for high-value tasks.
- **Expected traffic share:** ~15%

### n8n Pipeline Usage

n8n workflows calling OpenClaw programmatically should specify the agent per-workflow based on task complexity. Recommendation:

- Batch/bulk document processing workflows: use `code-helper` (moderate tier)
- Simple notification/formatting workflows: use `quick-chat` (simple tier)
- Complex orchestration workflows: use `deep-coder` (complex tier)

Bursty n8n traffic is bounded by the per-provider RPM limits. If a runaway workflow exhausts a provider's RPM, normal tier fallback handles it -- no dedicated rate-limit bucket needed since RPM limits are provider-global, not per-agent.

## Projected Cost Split

- **~80-90% free:** `quick-chat` (all free) + `code-helper` + `infra-ops` (free primary, paid last-resort fallback)
- **~10-20% paid:** `deep-coder` (paid primary) + occasional moderate-tier escalations to DeepSeek
- **Estimated monthly cost:** $0-5 (assuming moderate daily usage)

The range accounts for moderate-tier requests that may escalate to DeepSeek when NVIDIA NIM and Gemini are rate-limited.

## Observability

Monitor cost drift with `openclaw stats usage --period 7d` weekly. If DeepSeek spend exceeds $3 in a rolling 7-day period, investigate whether moderate-tier escalations are higher than expected.

Future enhancement: add an n8n workflow that queries `openclaw stats usage` daily and sends a notification if DeepSeek spend exceeds threshold.

## Configuration Changes

### Files Modified

1. **`roles/openclaw/defaults/main.yml`** -- New variables for agent definitions and tier mappings
2. **`roles/openclaw/templates/config.yaml.j2`** -- Expand `agents` block with tiers and definitions

No changes to docker-compose, networking, or other infrastructure.

**Scope note:** The config template has other uncommitted simplifications (removal of aliases, heartbeat, rateLimit, security blocks) that are a separate change. This spec covers only the addition of agent tiers and definitions.

### Ansible Variable Structure

New variables in `defaults/main.yml`:

```yaml
# Agent tier definitions -- model fallback chains per complexity level
# Each list entry is a "provider/model" ID matching the providers block
openclaw_agent_tiers:
  simple:
    timeout: 10  # seconds
    models:
      - "groq/llama-3.3-70b-versatile"
      - "nvidia/kimi-k2.5"
      - "google/gemini-2.5-flash"
  moderate:
    timeout: 30  # seconds
    models:
      - "nvidia/kimi-k2.5"
      - "google/gemini-2.5-flash"
      - "deepseek/deepseek-chat"
  complex:
    timeout: 120  # seconds
    models:
      - "deepseek/deepseek-chat"
      - "deepseek/deepseek-reasoner"
      - "google/gemini-2.5-flash"

# Agent definitions -- named agents with tier assignment and system prompts
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

### Relationship to Existing Config

The existing `agents.defaults.model` (set to `{{ openclaw_primary_model }}`) is preserved. It serves as the fallback when no specific agent is requested. The new `tiers` and `definitions` keys are siblings to `defaults` inside the `agents` block.

### Generated JSON Structure

The config template generates JSON. The expanded `agents` block will look like:

```json
{
  "agents": {
    "defaults": {
      "model": "nvidia/kimi-k2.5"
    },
    "tiers": {
      "simple": {
        "timeout": 10,
        "models": ["groq/llama-3.3-70b-versatile", "nvidia/kimi-k2.5", "google/gemini-2.5-flash"]
      },
      "moderate": {
        "timeout": 30,
        "models": ["nvidia/kimi-k2.5", "google/gemini-2.5-flash", "deepseek/deepseek-chat"]
      },
      "complex": {
        "timeout": 120,
        "models": ["deepseek/deepseek-chat", "deepseek/deepseek-reasoner", "google/gemini-2.5-flash"]
      }
    },
    "definitions": {
      "quick-chat": {
        "tier": "simple",
        "system_prompt": "You are a concise assistant. Give direct answers without preamble or filler."
      },
      "code-helper": {
        "tier": "moderate",
        "system_prompt": "You are a code assistant focused on quality. Follow existing patterns in the codebase. Provide working code without over-engineering. Prefer immutable patterns."
      },
      "infra-ops": {
        "tier": "moderate",
        "system_prompt": "You are a homelab infrastructure assistant. The homelab has two nodes: lw-main (10.0.0.1) and lw-s1 (10.0.0.2). Services run in Docker with Caddy reverse proxy, Vault for secrets, and Pi-hole for DNS. Answer in terms of the actual stack."
      },
      "deep-coder": {
        "tier": "complex",
        "system_prompt": "You are a senior software engineer. Provide thorough reasoning with trade-off analysis. Produce complete, tested solutions. Consider architectural implications."
      }
    }
  }
}
```

### Conditional Tier Construction

Tiers reference models from providers that may not be configured (e.g. DeepSeek key missing). The Jinja2 template must filter tier model lists to only include models whose provider has a valid API key. If a tier's model list becomes empty after filtering, that tier is omitted from the config.

Example: without a DeepSeek API key, the `complex` tier degrades to `["google/gemini-2.5-flash"]` only, and the `moderate` tier loses its last-resort fallback.

If a tier's model list is empty after filtering, that tier is omitted from the config and any agent definitions referencing it fall back to `agents.defaults.model` instead.

## Testing Plan

### 1. Routing Verification

Send sample prompts to each agent, then check `openclaw stats usage` to confirm the correct models are handling requests:

- `quick-chat`: "What time is it?" -> should hit `groq/llama-3.3-70b-versatile`
- `code-helper`: "Write a Python function to parse JSON" -> should hit `nvidia/kimi-k2.5`
- `infra-ops`: "How do I restart the Caddy container?" -> should hit `nvidia/kimi-k2.5`
- `deep-coder`: "Refactor this 500-line module into smaller files" -> should hit `deepseek/deepseek-chat`

### 2. Fallback Test

Hammer Groq past its 30 RPM limit with rapid `quick-chat` requests. Verify via logs that requests cascade to `nvidia/kimi-k2.5`.

### 3. Negative Cases

- Send a request with an invalid agent name -> should fall back to `agents.defaults.model`
- Temporarily set an invalid API key for a provider -> verify tier skips that provider's models
- Send a request when all simple-tier providers are rate-limited -> verify HTTP 503 response

### 4. Cost Audit

Run a mixed workload for 24 hours, then check `openclaw stats usage --period 1d`:

- Confirm ~80-90% of requests served by free models
- Confirm DeepSeek usage stays under the $0-5/month projected rate
- Identify any unexpected escalation patterns
