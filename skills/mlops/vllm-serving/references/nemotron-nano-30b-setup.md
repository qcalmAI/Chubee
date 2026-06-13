# Nemotron-3-Nano-30B-A3B-FP8 — Session-Specific Setup Notes

> ⚠️ **STALE-STATE WARNING.** This file is a point-in-time snapshot, not live truth.
> On this single-GPU swap system the loaded model changes between sessions. A later
> session confirmed this file was WRONG on multiple points: it claimed Nemotron was the
> loaded primary + `swap-model.sh` existed + a `vllm-nemotron` service was defined — at
> that time `vllm-super` was actually serving `local/qwen2.5-32b`, NO swap script existed,
> and NO `vllm-nemotron` service was in compose. **Always run the pre-flight probe in
> SKILL.md ("Verify live state FIRST") before trusting anything below.** The CONFIG
> RECIPES here are still valid as recipes; the STATE claims are not.

**System:** NVIDIA GB10 unified memory (119.7 GiB), Hermes Agent, vLLM Docker, Hermes Master Build Bible

## The Setup

This model was downloaded from HuggingFace and configured as the primary local inference model. Qwen2.5-32B weights REMAIN ON DISK (`/mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4`) — switching the loaded model does NOT delete them. The two coexist on disk; only one loads into the single GPU at a time.

### Weight Location
```
/mnt/chubee-data/super-weights/
├── NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/   # reserve model (not loaded)
├── nano_v3_reasoning_parser.py                  # reasoning parser plugin for vLLM
└── (Nemotron-3-Nano weights loaded directly via HF hub path at runtime)
```

### Docker Compose Configuration

**docker-compose.yml** for the vllm-super service:

```yaml
vllm-super:
  image: vllm-node:latest
  container_name: vllm-super
  restart: unless-stopped
  ports:
    - 8000:8000
  volumes:
    - /mnt/chubee-data/super-weights:/weights:ro
    - /mnt/chubee-data/docker-volumes/vllm-hf-cache:/hf-cache
  environment:
    - HF_HOME=/hf-cache
    - VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
    - VLLM_FLASHINFER_ALLREDUCE_BACKEND=trtllm
    - VLLM_USE_FLASHINFER_MOE_FP8=1
    - VLLM_FLASHINFER_MOE_BACKEND=throughput
  command: >
    vllm serve nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
    --served-model-name nemotron-nano-30b
    --trust-remote-code
    --async-scheduling
    --dtype auto
    --max-model-len ${VLLM_MAX_MODEL_LEN}
    --kv-cache-dtype fp8
    --gpu-memory-utilization ${VLLM_GPU_MEM_UTIL}
    --enable-chunked-prefill
    --enable-auto-tool-choice
    --tool-call-parser qwen3_coder
    --reasoning-parser-plugin nano_v3_reasoning_parser.py
    --reasoning-parser nano_v3
    --port 8000
```

### .env Values

```
VLLM_IMAGE_TAG=latest
VLLM_GPU_MEM_UTIL=0.85
VLLM_MAX_MODEL_LEN=262144
```

### Hermes Config Integration

```yaml
# ~/.hermes/config.yaml — CORRECT alias key (no local/ prefix)
model:
  default: nemotron-nano-30b        # bare name = vLLM served-model-name
  provider: custom:local

custom_providers:                   # ACTIVE format — NOT providers.custom.local
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions

model_aliases:
  nemotron-nano-30b:                 # KEY = model ID vLLM serves (no prefix!)
    model: nemotron-nano-30b
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
  nemotron-reasoning:
    model: nemotron-3-super
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
    extra_body:
      chat_template_kwargs:
        enable_thinking: true
  nemotron-fast:
    model: nemotron-3-super
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1
    extra_body:
      chat_template_kwargs:
        enable_thinking: false
  frontier:
    model: deepseek/deepseek-v4-flash
    provider: openrouter
```

## Failure Pattern: Config Mismatch

The vLLM server was successfully reconfigured to serve Nemotron-3-Nano (verified via `/v1/models` and live inference test). However, `~/.hermes/config.yaml` was never updated — it still had `model.default: deepseek/deepseek-v4-flash` with `provider: openrouter`.

**This is a repeat of the exact same pattern from the Qwen swap.** In both cases:
1. ✅ Docker compose was edited correctly
2. ✅ vLLM restarted and served the right model
3. ✅ Server responded correctly to curl tests
4. ❌ Hermes config.yaml was not updated
5. ❌ Every session hit OpenRouter (or failed silently)

### Root Cause

The config edit was discussed and several sessions attempted fixes, but each time the `patch` tool's success output was misleading — the file didn't actually change. On SSH-backed sessions, path resolution for `~` can diverge between the file tools and terminal tools. Always verify with `cat ~/.hermes/config.yaml | grep -A 2 '^model:'` after applying.

## Verified Live Numbers (GB10, vLLM 0.22.2.dev0, 262K context, gpu-util 0.85)

Measured during a clean Nemotron boot — these are the real figures, use them:

| Metric | Value |
|--------|-------|
| Checkpoint size | 30.44 GiB FP8 |
| Model loading took | **31.45 GiB / ~189 s** (weights only) |
| Available KV cache | 65.85 GiB |
| **GPU KV cache size** | **21,562,322 tokens** |
| **Max concurrency @262K** | **82.25×** |
| Full boot to healthy | ~3.5–5 min (weights + CUDA graph capture + KV setup) |

Contrast: Qwen2.5-32B on the same box gave 651,456 KV tokens / **2.49×** concurrency.
Mamba layers store no KV → Nemotron fits ~33× more cache and serves ~33× more
concurrent requests. This is why a "swarm" (many concurrent sessions on ONE vLLM)
is viable on a single GPU — you do NOT run N model processes.

## Dual served-model-name (REQUIRED — dashboard prefix)

Serve BOTH the bare and `local/`-prefixed name so every Hermes path resolves.
The CLI sends the bare alias key; the **dashboard/gateway picker forces `local/`**
regardless of alias name. In compose YAML array form each name is its own list item
(NOT comma-joined — a comma makes ONE literal name and breaks both):

```yaml
    - --served-model-name
    - nemotron-nano-30b
    - local/nemotron-nano-30b
```

Hermes `model_aliases` then needs BOTH keys, each pointing at `custom:local` → :8000.

## Verified working command (2026-06, primary on :8000)

The `--reasoning-parser-plugin` path must be the IN-CONTAINER path. With weights
mounted at `/weights`, point it at `/weights/nano_v3_reasoning_parser.py` (NOT a
bare filename — vLLM resolves it relative to cwd otherwise). Confirmed-good args:
`--max-model-len 262144 --kv-cache-dtype fp8 --gpu-memory-utilization 0.85
--enable-chunked-prefill --enable-auto-tool-choice --tool-call-parser qwen3_coder
--reasoning-parser-plugin /weights/nano_v3_reasoning_parser.py --reasoning-parser nano_v3`.
Env: `VLLM_USE_FLASHINFER_MOE_FP8=1`, `VLLM_FLASHINFER_MOE_BACKEND=throughput`,
`VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`.

## Inference-test gotcha (reasoning model)

A `max_tokens` that's too low returns `content: null` with a populated `reasoning`
field — the model spent the whole budget thinking. This looks like a failure but
isn't. Use `max_tokens >= 200` for the smoke test, and check the `reasoning` field
to confirm the `nano_v3` parser loaded. Native context per config is 262K but
NVIDIA's tech report + HF confirm the model trains for up to **1M tokens** — the
262K in config.json is a vLLM batch-sizing default, NOT a ceiling. Raise
`--max-model-len` toward 524288/1048576 to use it (Mamba KV stays cheap).

## Known Working State (point-in-time — verify live, see warning at top)

- vLLM container: `vllm-super` at `:8000`, serving `nemotron-nano-30b` + `local/nemotron-nano-30b`
- Context window: 262,144 tokens (native — no YaRN needed; extensible to 1M)
- Qwen weights remain on disk (NOT deleted) — switching the loaded model does not remove them