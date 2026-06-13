---
name: tiered-model-operations
description: "Run a fast local model as default workhorse with **manual-only** frontier-model escalation. Covers primary model setup, the model-swap protocol (vLLM container + Hermes config — two independent systems), escalation decision framework, usage logging, and weekly review cadence. Use when setting up model tiering, debugging routing 404s, or adjusting escalation thresholds."
version: 2.1.0
author: Quinton Calmus
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [model-tiering, escalation, frontier, local-llm, openrouter, cron, logging]
    related_skills: [hermes-agent, vllm-serving]
---

# Tiered Model Operations

## When to Load

Load when:
- Setting up or maintaining a primary (local) + secondary (frontier/remote) model tier
- Deciding whether to escalate a task to a more capable model
- Debugging why a local model gets 404 errors
- Setting up escalation logging and weekly review

## Architecture

```
Primary (default)              Frontier (escalate)
─────────────────              ───────────────────
Local vLLM :8000               OpenRouter
Fast, stable, free             Capable, paid-per-use
No network needed              Network round-trip
        │                              ▲
        │  for 95% of tasks            │  user decides, never agent
        ▼                              │
   execute directly            user starts fresh session with --model frontier
```

## Primary Model Setup

```yaml
# ~/.hermes/config.yaml
model:
  default: nemotron-nano-30b       # bare name — MUST match vLLM's --served-model-name
  provider: custom:local

model_aliases:
  nemotron-nano-30b:
    model: nemotron-nano-30b
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1

custom_providers:
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions

# Frontier alias (for user-directed escalation only)
model_aliases:
  frontier:
    model: deepseek/deepseek-v4-pro
    provider: openrouter
```

## Alias Key Name Rule (Critical — #1 cause of local model 404s)

**Hermes sends the alias KEY name as the model ID in the API request.**
The `model:` field inside the alias is IGNORED for routing. Whatever the
alias key is named is exactly what vLLM must serve.

```yaml
# BROKEN — Hermes sends "local/qwen2.5-32b" → vLLM returns 404
model_aliases:
  local/qwen2.5-32b:
    model: qwen2.5-32b

# CORRECT — alias key matches vLLM's --served-model-name
model_aliases:
  qwen2.5-32b:
    model: qwen2.5-32b
```

`model.default` follows the same rule — bare name, no prefix.

To verify what vLLM expects:
```bash
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```

That output is the exact string your alias key and `model.default` must be.
For full reproduction of this failure pattern, see `references/alias-key-prefix-bug.md`.

## Model Swap Protocol

Two independent systems — updating one does NOT propagate to the other.

### Step 1: Swap the vLLM container

Edit `~/chubee/stack/docker-compose.yml`: change the model path in the vLLM
service's `command`, then restart:

```bash
docker compose -f ~/chubee/stack/docker-compose.yml up -d vllm-super
```

### Step 2: Update Hermes config

After vLLM is serving the new model, update Hermes to use it:

```bash
hermes config set model.default <bare-model-name>     # e.g. qwen2.5-32b — NO prefix
hermes config set model.provider custom:local
```

**⚠️ The alias key (and model.default) must be the BARE name, not `custom:local/<name>`.**
See the Alias Key Name Rule above. The `custom:local/` prefix is the #1 cause of 404s.

**Container swap ≠ config update.** Step 1 alone leaves Hermes silently routing
to the old provider. Always do both steps.

### Diagnosis: "Model is loaded but I get errors"

```bash
# 1. What is vLLM actually serving?
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data']]"

# 2. What is Hermes configured to use?
head -5 ~/.hermes/config.yaml

# 3. What alias key exists?
grep -A4 'nemotron\|qwen' ~/.hermes/config.yaml | head -10
```

**Troubleshooting matrix:**

| vLLM model | model.default | Alias key | Result |
|---|---|---|---|
| `qwen2.5-32b` | `qwen2.5-32b` | `qwen2.5-32b` | Works |
| `qwen2.5-32b` | `deepseek/deepseek-v4-pro` | (any) | Hitting OpenRouter, not local |
| `qwen2.5-32b` | `local/qwen2.5-32b` | `local/qwen2.5-32b` | **404** — alias key has prefix |

For full reproduction (what went wrong, exact commands missed, diagnosis flow):
`references/model-swap-caveat.md`.

## Escalation Framework

### Policy: Manual Only — No Auto-Escalation

> **Escalation to the frontier model is a deliberate user decision, never an agent
> initiative.** If the local model fails, let it fail. Do not autonomously switch
> models, delegate to frontier, or inject a model change mid-session.

### When to Offer Escalation (tell the user, do not act)

1. **Constraints** — sustained multi-step logical reasoning across >5 interdependent
   constraints where local output is insufficient
2. **Quality** — output where quality matters more than speed: important correspondence,
   medical/legal/financial analysis, architectural decisions
3. **Self-assessment** — you've produced output, assessed it, judged it insufficient
4. **User request** — user explicitly asks for best possible output

Do NOT offer for mechanical, procedural, or routine work.

### Escalation Mechanism (user-directed)

1. **New session**: `hermes --model frontier` or use the `frontier` alias
2. **Single task**: `delegate_task` with model override to frontier
3. **Log it** (always, before delegating):

```bash
echo "$(date '+%Y-%m-%d %H:%M') | <one-line task> | <reason>" >> ~/chubee/frontier-usage.log
```

Reasons: `constraints`, `quality`, `self-assessment`, `user-request`

## Context Window Management

Two strategies, applied in order:

### Strategy 1: Context Compression (do first)

```bash
hermes config set compression.enabled true
hermes config set compression.threshold 0.85
hermes config set compression.target_ratio 0.50
```

### Strategy 2: YaRN RoPE Scaling

See `vllm-serving` skill for the full procedure. Quick reference for GB10:

| Parameter | Value |
|---|---|
| GPU-memory-utilization | 0.45 (for 64K) |
| max-model-len | 65536 (32K × 2× YaRN) |
| KV cache at 64K (fp8) | ~8 GiB |

For reliable long-context beyond 2×, prefer a model with native support (Nemotron-3-Nano
at 256K+ native via Mamba).

## Weekly Review Cadence

Cron runs every Sunday 9am local. Reads `~/chubee/frontier-usage.log`, counts
escalations by reason, sends Telegram DM.

Assessment thresholds:
- **0-4/week**: ✅ Low — second GPU not warranted
- **5-9/week**: 👀 Moderate — continue monitoring
- **10+/week**: ⚠️ Second GPU worth serious evaluation

## Pitfalls

### Routing
- **Alias key name = model ID sent to vLLM** (see rule above). #1 404 cause.
- **Container swap ≠ config update.** Always run `hermes config set` after any vLLM swap.
- **Old `providers` dict shadows `custom_providers`.** Delete the legacy `providers:` block;
  migrate to `custom_providers` list. See `vllm-serving` skill for full diagnosis.
- **Context window mismatch.** Swapping to a smaller-context model mid-session causes
  400/garbage. Always start a fresh session after a model swap.

### Escalation
- **Auto-escalation is forbidden.** Never autonomously switch or delegate to frontier.
- **Do not grind through local failures.** After assessing output as insufficient, bring
  it to the user — do not attempt a second local pass.
- **Always log before delegating.** The log is the data that justifies the second GPU.

### Config
- **`model.context_length` is GLOBAL.** It caps ALL models, not just the default.
  Remove or comment out when switching to higher-context models.
- **Hermes context-limit wall (64K minimum).** Some Hermes versions reject models with
  <64K native context regardless of config override. Workaround: actually extend the
  model's context via YaRN rather than relying on config alone.
- **Gateway caches config at start.** After config edits in Docker mode: `docker restart hermes`.
- **Stale download processes corrupt model files.** Run the kill pattern (see `vllm-serving`)
  before any model-file operation.

## Verification

```bash
# Check config
head -5 ~/.hermes/config.yaml

# Check frontier alias
grep -A3 "frontier:" ~/.hermes/config.yaml

# Check log exists
cat ~/chubee/frontier-usage.log

# Test vLLM responds
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<served-model-name>","messages":[{"role":"user","content":"ping"}],"max_tokens":5}'
```

## Execution Style

When the user has already been given diagnostic results and proposed fixes, **execute
immediately** — do not re-list the plan and ask for permission. The diagnostic phase
happened; the action phase follows without re-litigating. This applies across ALL skills.
