---
name: vllm-serving
description: "Configure, tune, and troubleshoot vLLM inference servers on unified-memory systems (GB10). Covers the local-model install checklist (ordered, non-negotiable), memory/KV cache sizing, the alias-key routing rule (#1 404 cause), two-point empirical KV sizing, post-deployment Hermes wiring, and diagnostic workflow. Use when setting up a new model, tuning GPU memory, or debugging routing/memory/corruption issues."
version: 1.4.0
author: Hermes Agent + user
metadata:
  hermes:
    tags: [vllm, inference, serving, gpu-memory, kv-cache, unified-memory, routing]
    related_skills: [tiered-model-operations, docker-compose-services, hermes-agent]
---

# vLLM Serving — Configuration & Troubleshooting

## Local Model Install Checklist

**Run these steps STRICTLY in order. Skipping or reordering is the #1 cause of
repeated 404 routing failures on this system.**

(a) **Decide the canonical model name.** Pick the exact string that will be the
model ID everywhere (e.g. `qwen2.5-32b`). The `--served-model-name` value, the
Hermes alias key, and `model.default` must ALL equal it.

(b) **Add it to `--served-model-name` in docker-compose.** Edit the vLLM service
so it serves exactly that name. If the dashboard path is needed, serve BOTH names
space-separated (see dashboard exception below).

(c) **Restart vLLM and verify with curl.** `docker compose up -d <service>`, then:
```bash
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```
Confirm the canonical name appears. Do NOT proceed until vLLM actually serves it.

(d) **Set the Hermes alias key to that exact name.** The `model_aliases` key
(and `model.default`) must equal the verified name — no `local/`, no `custom:`
prefix. The alias's inner `model:` field is irrelevant for routing.

(e) **Restart Hermes.** Config is cached at process start. Docker: `docker restart hermes`.
CLI: fresh session.

**Why this order is non-negotiable:** Hermes sends the alias KEY as the model ID.
If you configure the alias before vLLM serves a matching name, routing fails silently
(falls through to OpenRouter → 404).

## Alias Key Name Rule (Critical — #1 404 cause)

**Hermes sends the alias KEY name as the model ID. NOT the `model:` field inside
the alias.** Whatever you name the alias key is exactly what vLLM must serve.

```yaml
# BROKEN — Hermes sends "local/qwen2.5-32b" → vLLM 404
model_aliases:
  local/qwen2.5-32b:
    model: qwen2.5-32b

# CORRECT — alias key matches vLLM's --served-model-name
model_aliases:
  qwen2.5-32b:
    model: qwen2.5-32b
```

`model.default` follows the same rule — bare name, no prefix.

### ⚠️ Dashboard exception: serve BOTH names

The dashboard model picker sends `local/<name>` WITH the prefix regardless of
alias key name. Fix: serve BOTH names space-separated:
```bash
--served-model-name qwen2.5-32b local/qwen2.5-32b
```
**CRITICAL: SPACE-separated, NOT comma-separated.** A comma makes ONE literal
model name. Each name must be its own list item in YAML array form:
```yaml
command:
  - vllm; - serve; - /weights/...
  - --served-model-name
  - qwen2.5-32b
  - local/qwen2.5-32b      # own line, NOT comma-joined
```

## Model Coexistence: Both On Disk, One Loaded

Single-GPU/unified-memory: only ONE model loaded at a time. But weights coexist
on disk indefinitely. Swapping changes which is loaded, not which exists.

**Hermes and vLLM are DECOUPLED.** Setting `model.default: nemotron-nano-30b`
does NOT auto-load Nemotron — it only changes which model ID Hermes requests.
If vLLM still serves Qwen, Hermes asks for Nemotron → 404. The "set default →
auto-load" expectation requires glue (swap script, see `tiered-model-operations`).

## Current System State (GB10, 119.7 GiB unified)

Probe before any operation — don't trust stale docs:
```bash
# 1. What is the GPU actually serving RIGHT NOW?
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; [print(m['id'],'ctx:',m.get('max_model_len','?')) for m in json.load(sys.stdin)['data']]"
# 2. What weights / HF cache exist on disk?
ls -la /mnt/chubee-data/super-weights/
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/ | grep -i <model>
# 3. What does Hermes config actually point at?
grep -nE "^  default|nemotron|qwen" ~/.hermes/config.yaml | head
# 4. Wedged docker processes from prior sessions?
ps aux | grep -iE "docker compose up|docker cp|docker rm -f" | grep -v grep | awk '{print $2,$11,$12,$13}'
```

If `docker logs`/`docker inspect` hang, kill stale docker wrappers first:
```bash
ps aux | grep -iE "docker compose up|docker cp .*vllm|docker rm -f" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
```

## Memory Budget & KV Cache Sizing

### Key Concepts

On unified memory (GB10), `nvidia-smi` shows `[N/A]` — there's no separate VRAM.
vLLM's `--gpu-memory-utilization` controls the fraction of the SHARED pool.

```
gpu-memory-utilization × total_memory = reserved_for_vllm
reserved_for_vllm = model_weights + cuda_graphs_overhead + KV_cache_pool
```

KV bytes per token (fp8):
```
bytes_per_token = 2 × num_layers × num_kv_heads × head_dim × dtype_bytes
```
Where `dtype_bytes`: fp8/int8=1, fp16/bf16=2, fp32=4.

### Two-Point Empirical KV Sizing (preferred when vLLM is running)

Instead of deriving from architecture, read off two real boot logs at different
`gpu-memory-utilization` values and solve linearly:

```
per_token_GiB   = (KV_GiB_hi − KV_GiB_lo) / (tokens_hi − tokens_lo)
fixed_overhead   = (util_lo × total_mem) − KV_GiB_lo
budget           = tokens_target × per_token_GiB_per_M + fixed_overhead
```

Worked example (GB10, Nemotron-Nano, 262K max-len, fp8):
- 0.85 → 65.85 GiB KV / 21,562,322 tokens
- 0.75 → 54.14 GiB KV / 17,727,977 tokens
- per-token ≈ **3.06 GiB per 1M tokens**
- fixed ≈ **35.6 GiB**

### Example (Qwen2.5-32B-GPTQ-Int4)

| Parameter | Value |
|---|---|
| Layers | 64 |
| KV heads | 8 |
| Head dim | 128 |
| KV dtype | fp8 (1 B) |
| **KV bytes/token** | **131,072 B ≈ 0.128 MB** |
| Model weights | 18.02 GiB |
| CUDA graph overhead | ~0.8 GiB |
| Max context len | 32,768 |

4 concurrent 32K requests → 16.8 GiB KV → total 35.6 GiB → util **0.30**.

### Caveat: `gpu-memory-utilization` hardcoded in compose

`.env` can define `VLLM_GPU_MEM_UTIL=0.60` while compose has a literal `"0.85"` —
the env var is silently unused. Always verify:
```bash
docker compose config 2>/dev/null | grep -A1 gpu-memory-util
```
Wire it: `- "${VLLM_GPU_MEM_UTIL:-0.60}"`.

## Diagnostic Workflow

### 1. Check what's served
```bash
curl -s http://localhost:8000/v1/models | python3 -m json.tool
curl -s http://localhost:11434/api/tags | python3 -m json.tool   # Ollama
```

### 2. Get total GPU-accessible memory
```bash
docker exec <vllm-container> python3 -c "
import torch
p = torch.cuda.get_device_properties(0)
print(f'GPU: {p.name}')
print(f'Total mem: {p.total_memory / 1024**3:.1f} GiB')
print(f'Allocated: {torch.cuda.memory_allocated(0) / 1024**3:.1f} GiB')
print(f'Reserved:  {torch.cuda.memory_reserved(0) / 1024**3:.1f} GiB')
"
```

### 3. Find model weight usage and KV cache
```bash
docker logs <vllm-container> 2>&1 | grep -i 'model loading took\|GPU KV cache size\|Available KV cache'
```

### 4. Derive KV bytes/token
```python
layers = 64; kv_heads = 8; head_dim = 128; dtype_bytes = 1  # fp8
bytes_per_token = 2 * layers * kv_heads * head_dim * dtype_bytes
print(f'{bytes_per_token / 1024:.1f} KB/token')
```

### 5. Calculate needed gpu-memory-utilization
```python
total_mem = 119.7; model_weights = 18.02; overhead = 0.8
max_context = 32768; bytes_per_token = 131072; concurrent = 4
kv_needed = max_context * concurrent * (bytes_per_token / 1073741824)
budget = model_weights + overhead + kv_needed
print(f'KV needed: {kv_needed:.1f} GiB; Budget: {budget:.1f} GiB; Util: {budget/total_mem:.2f}')
```

### 6. Apply and verify
```yaml
command: >
  vllm serve /weights/model-name
  --served-model-name model-name
  --gpu-memory-utilization 0.30
  --max-model-len 32768
```
Then: `docker compose up -d <service>` and verify with `docker logs`.

## Post-Deployment: Connect to Hermes

vLLM running a model does NOT mean Hermes uses it. The most common failure:
setting up vLLM correctly, never telling Hermes.

### Required Hermes config
```yaml
model:
  default: <model-name>          # MUST match vLLM served-model-name
  provider: custom:local

model_aliases:
  <model-name>:
    model: <model-name>
    provider: custom:local
    base_url: http://172.17.0.1:8000/v1

custom_providers:
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions
```

### Config File Anatomy: `custom_providers` is Active

**⚠️ Resolution order bug.** Hermes checks the OLD `providers:` dict FIRST.
If both old and new formats exist with different `base_url` values, the old one
wins and requests silently fall through to OpenRouter (404).

```yaml
# REMOVE — old format, takes wrong priority:
providers:
  custom:
    local:
      base_url: http://vllm-super:8000    # may not resolve

# KEEP — new format, correct URL:
custom_providers:
  - name: local
    base_url: http://172.17.0.1:8000/v1    # host gateway IP
    api_mode: chat_completions
```

Verify old format is gone:
```bash
docker exec hermes python3 -c "import yaml; c=yaml.safe_load(open('/opt/data/config.yaml')); print(list(c.get('providers',{}).keys()))"
# Expected: []
```

### Verification Checklist

When a local model doesn't work:
1. Is vLLM running? `docker ps --filter name=vllm`
2. Is vLLM healthy? `docker inspect <container> --format '{{.State.Health.Status}}'`
3. Does vLLM respond? `curl -H "Content-Type: application/json"` to `/v1/chat/completions`
4. Does Hermes config point at it? Check `model.default` + `model.provider`
5. Does `custom_providers` have a `local` entry with correct `base_url`?
6. Is the alias key exactly equal to vLLM's model ID? (#1 cause)
7. Is the old `providers:` dict shadowing `custom_providers`? (resolution-order bug)

## Model Lifecycle: Swapping

Required steps every swap:
1. Check weights exist on disk: `ls /mnt/chubee-data/super-weights/`
2. **Kill stale download processes** (see `references/stale-process-corruption.md`)
3. Update docker-compose.yml — change model path in vLLM command
4. Update `.env` — `VLLM_MAX_MODEL_LEN` and `VLLM_GPU_MEM_UTIL`
5. Restart vLLM: `docker compose up -d vllm-super`
6. Verify vLLM serves: `curl -s http://localhost:8000/v1/models`
7. Update Hermes config: `model.default` + `model.provider` + `model_aliases`
8. Start a fresh session — model changes take effect on fresh sessions only

**Known failure pattern:** Steps 1-5 done, step 7 skipped. Later sessions silently
fall back to OpenRouter.

## Quick Reference Tables

### Nemotron-3-Nano-30B-A3B-FP8 (MoE+Mamba, verified v0.22.2.dev)
```yaml
# docker-compose.yml command:
- vllm; - serve; - /weights/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
- --served-model-name; - nemotron-nano-30b; - local/nemotron-nano-30b
- --trust-remote-code
- --max-model-len; - "262144"
- --kv-cache-dtype; - fp8
- --gpu-memory-utilization; - "0.85"
- --enable-auto-tool-choice
- --tool-call-parser; - qwen3_coder
- --reasoning-parser-plugin; - /weights/nano_v3_reasoning_parser.py
- --reasoning-parser; - nano_v3

environment:
  HF_HOME: /hf-cache
  VLLM_ALLOW_LONG_MAX_MODEL_LEN: "1"
  VLLM_USE_FLASHINFER_MOE_FP8: "1"
  VLLM_FLASHINFER_MOE_BACKEND: throughput
```
Measured at gpu-util 0.85: weights 31.45 GiB · KV pool 65.9 GiB · **11.96M tokens** capacity.

Live test gotcha: reasoning model may leave `content: null` if `max_tokens` too small
(budget consumed mid-think). Use `max_tokens >= 200` for hello-world. Reasoning trace
populated + null content = success, not failure.

### Qwen2.5-32B-GPTQ-Int4 (dense, archived)
```yaml
- vllm; - serve; - /weights/Qwen2.5-32B-Instruct-GPTQ-Int4
- --served-model-name; - qwen2.5-32b; - local/qwen2.5-32b
- --gpu-memory-utilization; - "0.30"
- --max-model-len; - "32768"
```
Archived at `/mnt/chubee-data/Qwen2.5-32B-Instruct-GPTQ-Int4.tar.gz`.
For Nemotron ↔ Qwen tradeoffs, see `tiered-model-operations` skill.

## Pitfalls

- **Alias key name = model ID sent** (see rule above). #1 404 cause.
- **Old `providers` dict shadows `custom_providers`.** Delete the legacy block.
- **`model.context_length` is GLOBAL** — caps ALL models, not just default.
- **Container swap ≠ config update.** Two independent systems.
- **Do NOT set gpu-memory-utilization too low (< 0.15).** Weights need room.
- **`free -h` includes GPU reservations** on unified memory — check `available`.
- **`nvidia-smi` showing `[N/A]` = unified memory.** Trust `torch.cuda`.
- **KV cache pre-allocated, not pre-filled** — 0% usage at idle is normal.
- **`--force-download` reverts `config.json`** — re-apply rope_scaling after.
- **Bash `!` in HF tokens** triggers history expansion — use single quotes.
- **Verify HF_TOKEN validity BEFORE downloading** — expired tokens cause SIGTERM
  mid-stream, not just slow speeds.

## Reference Library

- **Stale process contamination** (kill pattern, safetensor validation, recovery):
  `references/stale-process-corruption.md`
- **Quantization mismatch across shards** (GPTQ shards from different sources):
  `references/quantization-mismatch.md`
- **Docker Compose YAML corruption** (repeated patching, orphaned list items):
  `references/yaml-corruption.md`
- **YaRN RoPE scaling** (full procedure, Qwen2 vLLM version support, hf-overrides):
  `references/yarn-rope-scaling.md`
- **Building vLLM from source** (tmux detachment, aarch64 CUDA torch, build cache):
  `references/building-from-source.md`
- **Nemotron-Nano setup** (full config, architecture comparison):
  `references/nemotron-nano-30b-setup.md`
- **HF model download to Docker volume** (snapshot_download, lock-stalling):
  `references/hf-model-download-to-docker-volume.md`
- **Large model archiving** (tarball, RESTORE-README):
  `references/nemotron-120b-archive.md`
- **vLLM upgrade for YaRN on Qwen** (v0.21 → v0.22+):
  `references/vllm-upgrade-yarn-qwen.md`
