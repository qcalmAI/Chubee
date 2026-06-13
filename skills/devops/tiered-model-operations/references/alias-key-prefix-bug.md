# Alias Key Prefix Bug — Reproduction & Diagnosis

## The Failure Pattern

This is the #1 cause of "local model 404" errors on this system. It went undiagnosed across four sessions because the symptom looks like a config reversion.

### Symptom

1. User or agent sets `model.default` and creates a model alias pointing at local vLLM
2. vLLM is confirmed healthy — `curl` to `/v1/models` shows the model, inference works with direct API calls
3. Hermes sessions with the local model fail immediately — no assistant response, just an error
4. Error from logs: `HTTP 404: The model \`local/nemotron-nano-30b\` does not exist.`
5. Previous diagnosis: "config was never updated" or "config keeps reverting"
6. User manually swaps back to OpenRouter/DeepSeek to troubleshoot

### Root Cause

**Hermes sends the alias KEY name as the `model` field in the API request to vLLM — NOT the `model` field inside the alias.**

Given:
```yaml
model_aliases:
  local/nemotron-nano-30b:       # ← This key name is what Hermes sends
    model: nemotron-nano-30b       # ← This field is ignored for model ID
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
```

Hermes calls vLLM with `{"model": "local/nemotron-nano-30b", ...}`.
vLLM responds: `404: The model \`local/nemotron-nano-30b\` does not exist.`
vLLM only knows `nemotron-nano-30b` (its `--served-model-name`).

### Why it was misdiagnosed

Every previous fix did **both** steps in the Model Swap Protocol (update vLLM AND update Hermes config). But because the alias key used the `local/` prefix, the config update was correct in intent but wrong in execution. The error looked like the config wasn't taking effect because:

1. The `model.default` was set to `local/nemotron-nano-30b` (with prefix)
2. This referenced an alias also named `local/nemotron-nano-30b`
3. The alias resolved to the right provider and base_url
4. But the alias KEY itself was sent to vLLM — 404 every time

Since the config visually looked right (provider: custom:local, base_url: correct), the assumption was "config reverted" rather than "alias key is wrong."

### The Fix

Rename the alias key to match vLLM's `--served-model-name` exactly. No prefix.

```yaml
# Before (broken)
model:
  default: local/nemotron-nano-30b

model_aliases:
  local/nemotron-nano-30b:
    model: nemotron-nano-30b

# After (fixed)
model:
  default: nemotron-nano-30b

model_aliases:
  nemotron-nano-30b:
    model: nemotron-nano-30b
```

### How to diagnose in one step

```bash
# What does vLLM expect?
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data']]"

# What is model.default?
head -3 ~/.hermes/config.yaml

# What is the alias key?
grep -E '^  [a-z]' ~/.hermes/config.yaml | grep -v '^  [a-z]*:' | head -5
# Or look for the aliases section specifically
grep -B1 -A4 'nemotron\|qwen' ~/.hermes/config.yaml
```

If `model.default` and the alias key include `local/` but vLLM serves the bare name, that's the bug.

### Affected Sessions

- `20260605_232620_7956a9` (Qwen, alias `local/qwen2.5-32b` → 400 error)
- `20260605_232643_77165e` (Qwen, same)
- `20260605_233505_0217c5` (crash recovery)
- `20260605_233804_72b14e` (Qwen failure analysis — misdiagnosed)
- `20260605_234404_fc2b0f` (Qwen garbled output — searched web for unrelated causes)
- `20260606_001358_0be3e1` (Nemotron, alias `local/nemotron-nano-30b` → 404)
- `20260606_002153_935565` (Nemotron, same — just "test" then crash)
- `20260606_001445_7c3701` (Nemotron config fix — misdiagnosed again)

### Lesson

When a local model consistently returns 404 and vLLM is healthy, do NOT assume the config reverted. Check the alias key name and `model.default` against vLLM's model ID. The error is in the alias key, not the alias body.