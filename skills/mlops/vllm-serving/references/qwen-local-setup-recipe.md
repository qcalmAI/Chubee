# Qwen2.5-32B Local Setup — Failure Autopsy & Re-Deployment

> **Status:** Deployed with YaRN context extension on `vllm-super` (port 8000).
> **Build:** `Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4`, loaded from HF cache via `hf` CLI.
> **Context:** 262,144 tokens (256K) via YaRN factor=8, or 524,288 (512K) via factor=16.
> **Alias fix applied:** Key name = `qwen2.5-32b` (no `local/` prefix).

**System:** NVIDIA GB10 unified memory (119.7 GiB), Hermes Agent, vLLM Docker, Qwen2.5-32B-Instruct-GPTQ-Int4

## The Saga (3 sessions, 2 failures)

### Failure 1: vLLM was serving Qwen, Hermes was ignoring it

Someone edited the Docker compose file to switch the container from Nemotron-3-Super to Qwen2.5-32B. `docker compose up -d vllm-super` ran and vLLM served Qwen at `:8000`. 

**But nobody ran `hermes config set model.default`.** The Hermes config still said:
```yaml
model:
  default: deepseek/deepseek-v4-flash
  provider: openrouter
```

Every session refresh still hit OpenRouter → DeepSeek. Qwen was sitting there ready, unused.

**Lesson:** Changing the vLLM Docker container does NOT change what Hermes uses. Two independent steps.

### Failure 2: Once pointed at Qwen, it crashed on context overflow

After ~3 sessions of debugging, the config was fixed. Hermes started routing through local Qwen. Then it crashed repeatedly. Root cause:

- Qwen2.5-32B native `max_position_embeddings` = 32,768
- Heavy tool-calling sessions blew past 32K tokens
- Positional encoding (RoPE) produced NaN beyond the limit
- vLLM engine crashed silently

**Fix:** YaRN 2× rope scaling injected into the model's `config.json` → extended to 65,536 tokens. Raised `gpu-memory-utilization` from 0.30 → 0.45 for KV cache headroom.

### Post-fix: Config patch didn't stick

After the YaRN fix was verified, someone ran `patch` to change `model.default` in `~/.hermes/config.yaml`. The tool reported success. But the config file was NOT actually changed — it still read `deepseek/deepseek-v4-flash`. Two subsequent sessions using `local/qwen2.5-32b` crashed immediately (model resolution failed).

**Lesson:** Always verify config changes by reading the file back. The patch tool can silently write to the wrong path resolution on SSH-backed sessions.

## YaRN Re-Deployment (Post-Alias-Fix)

After the alias fix was discovered (alias key must match vLLM's `--served-model-name` exactly), Qwen was re-deployed with proper context scaling.

### Context Window Sizing on GB10 (119.7 GiB unified)

| Context | YaRN Factor | KV Cache | Total Memory | Verdict |
|---------|------------|----------|-------------|---------|
| 32K (native) | — | ~4 GiB | ~21 GiB | default |
| 128K | 4x | ~16 GiB | ~33 GiB | comfortable |
| 256K | 8x | ~32 GiB | ~49 GiB | sweet spot |
| 512K | 16x | ~64 GiB | ~81 GiB | practical max |
| 1M | 32x | ~128 GiB | ~145 GiB | ❌ exceeds memory |

KV cache calculation: 2 × 64 layers × 8 KV heads × 128 head_dim × 1 byte (FP8) = 128 KB per token.

### YaRN via CLI Flag (newer vLLM)

When the `--rope-scaling` CLI flag is supported (vLLM ≥ some builds):

```bash
vllm serve /hf-cache/hub/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --served-model-name qwen2.5-32b \
  --rope-scaling '{"rope_type":"yarn","factor":8.0,"original_max_position_embeddings":32768}' \
  --max-model-len 262144
```

**CRITICAL:** Use `"rope_type": "yarn"` (not `"type": "yarn"`) in newer vLLM. Older config.json format used `"type"`.

### YaRN via config.json (version-dependent — verify first)

**This approach does NOT work for Qwen2 models on vLLM 0.21.x** — the Qwen2 model code in that version has zero references to `rope_scaling`. The config field is silently ignored, and extended context beyond native `max_position_embeddings` produces garbled text.

Verify before relying on it:
```bash
docker exec vllm-super grep -r "rope_scaling" /usr/local/lib/python3.12/dist-packages/vllm/model_executor/models/qwen2.py
```

If that returns nothing, YaRN is unavailable for Qwen in this vLLM build. Only native 32K is reliable.

If it DOES return matches, edit the model's config.json on disk before starting vLLM:

```json
"max_position_embeddings": 32768,
"rope_scaling": {
  "type": "yarn",
  "factor": 8.0,
  "original_max_position_embeddings": 32768
}
```

### Docker Compose YAML Quoting for rope-scaling JSON

When `command:` is a YAML string (not an array), single quotes inside must be doubled (`''`):

```yaml
command: >
  vllm serve /path ...
  --rope-scaling '{"rope_type":"yarn","factor":8.0,"original_max_position_embeddings":32768}'
  ...
```

**When `command:` is a YAML list (cleaner, no quoting issues):**

```yaml
command:
  - vllm
  - serve
  - /hf-cache/hub/Qwen2.5-32B-Instruct-GPTQ-Int4
  - --served-model-name
  - qwen2.5-32b
  - --rope-scaling
  - '{"rope_type":"yarn","factor":8.0,"original_max_position_embeddings":32768}'
  - --max-model-len
  - "262144"
```

### Weight Download

`huggingface-cli` is deprecated. Use `hf`:

```bash
docker exec vllm-super hf download Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --local-dir /hf-cache/hub/Qwen2.5-32B-Instruct-GPTQ-Int4
```

The `/weights` mount is read-only (`ro`) — download to `/hf-cache` instead.

### Hermes Config (Alias Fix Applied)

```yaml
# ~/.hermes/config.yaml
model:
  default: qwen2.5-32b          # MUST match served-model-name — NO local/ prefix
  provider: custom:local

custom_providers:                # Active format — NOT providers.custom.local!
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions

model_aliases:
  qwen2.5-32b:                  # Key = model ID vLLM serves (no prefix!)
    model: qwen2.5-32b
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
```

When user says "Qwen local doesn't work" or app crashes immediately:

```bash
# 1. Is the container running?
docker ps --filter name=vllm --format '{{.Names}} {{.Status}} {{.Ports}}'

# 2. Is vLLM healthy?
docker inspect vllm-super --format '{{.State.Status}} {{.State.Health.Status}}'

# 3. Does vLLM actually respond?
curl -s -H "Content-Type: application/json" \
  http://localhost:8000/v1/chat/completions \
  -d '{"model":"qwen2.5-32b","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
# ^^^ MUST include -H "Content-Type: application/json" or you get 400

# 4. What does Hermes config say?
cat ~/.hermes/config.yaml | grep -A 2 '^model:'

# 5. Does the provider definition exist?
cat ~/.hermes/config.yaml | grep -A 3 'custom_providers:'

# 6. What model names does vLLM report?
curl -s http://localhost:8000/v1/models

# 7. What's the actual vLLM command line?
docker inspect vllm-super --format '{{json .Config.Cmd}}' | python3 -m json.tool

# 8. Check .env for memory/context limits
cat ~/chubee/stack/.env | grep -E 'VLLM_MAX|VLLM_GPU'
```

## Hermes Config (Correct Format — Alias Key = Model ID)

```yaml
# In ~/.hermes/config.yaml
# Active format: custom_providers list (NOT providers.custom.local)

# Section 1: Default model
model:
  default: qwen2.5-32b          # MUST match vLLM served-model-name — no prefix!
  provider: custom:local

# Section 2: Provider definition (active format — required for routing)
custom_providers:
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions

# Section 3: Optional alias — KEY MUST equal vLLM model ID (no local/)
model_aliases:
  qwen2.5-32b:
    model: qwen2.5-32b
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
```

**Legacy format** (old `providers.custom.local` — NOT read by model routing):

```yaml
providers:
  custom:
    local:
      base_url: http://vllm-super:8000
      api_key: unused
```

If you find both in your config, move the provider definition to `custom_providers` and remove the `providers.custom.*` block. The model alias in `model_aliases` points at the provider by name (`custom:local`) regardless of which format defines it — but **only `custom_providers` is actually read**.

## Pitfalls

- **Content-Type header is required** on every vLLM curl. Without it you get `400 Unsupported Media Type: Only 'application/json' is allowed`. This looks like Qwen is broken but it's actually curl being curl.
- **`172.17.0.1` not `localhost`** — From inside the Hermes container (or the Hermes process on the host), Docker containers are reached via the Docker bridge gateway IP, not `localhost:8000`. `localhost` resolves to the container's own loopback, not the host.
- **Config patches via the `patch` tool may not persist** on SSH-backed sessions because path resolution for `~` differs between the file tools and the terminal tools. Always verify: `cat ~/.hermes/config.yaml | grep model`.
- **vLLM tool-call parser must match the model family.** Qwen2.5 uses `--tool-call-parser qwen3_coder` (or `qwen2` depending on version). Wrong parser crashes tool calls silently.
- **`huggingface-cli` is deprecated.** Use `hf` instead. Running `huggingface-cli download ...` exits with a deprecation warning and does nothing. Replace with `hf download ...`.
- **Cannot download to `/weights` — it's read-only.** The compose file mounts `/mnt/chubee-data/super-weights` as `:ro`. Download to the HF cache path (`/hf-cache/hub/<name>`) instead.
