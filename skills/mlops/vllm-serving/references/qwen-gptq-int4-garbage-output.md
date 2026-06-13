# Qwen2.5-32B-Instruct-GPTQ-Int4: Garbled Output on vLLM Dev Build

## Symptom

vLLM loads the model successfully (no safetensor errors, all shards parse), the
server starts and reports `Supported tasks: ['generate']`, but every inference
request returns garbage text — mixed English/Chinese tokens that decode to
nonsense like:

```
.sip后台召唤.magic Brennan召唤LowerCasePID铸片召唤不服
```

Output is identical across temperature/`top_p`/`top_k`/repetition penalty settings,
suggesting the issue is in the weight loading or arithmetic pipeline, not in
sampling config.

## Tested Configuration

| Parameter | Tested Values |
|-----------|--------------|
| Model | `Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4` (official, 480K downloads) |
| vLLM version | `0.21.1rc1.dev277+g716d5294e.d20260525` (nightly, May 25 2026) |
| Hardware | 1× NVIDIA GB10 (119.7 GiB unified memory) |
| Weight source | Fresh download from HF (aria2c, single-connection wget, snapshot_download) |
| Weight validation | Safetensor header valid, 4-bit GPTQ weights unpack correctly |
| Embedding table | Non-zero, correct fp16 range |
| Context length | 32,768 (native, no YaRN) |

## What DID NOT Fix It (all tried)

| Attempt | Result |
|---------|--------|
| `--kv-cache-dtype fp8` removed | Same garbage |
| `--enforce-eager` (no CUDA graphs) | Same garbage |
| `--dtype float16` explicitly | Same garbage |
| `--load-format safetensors` | Same garbage |
| `--gpu-memory-utilization 0.35/0.65/0.85` | Same garbage |
| Fresh download to different volume | Same garbage |
| Copy clean weights from successful aria2c batch | Same garbage |
| Native 32K context (no VLLM_ALLOW_LONG_MAX_MODEL_LEN) | Same garbage |
| Default Qwen system prompt vs custom | Same garbage |
| Weight validation: all shards non-zero, proper ranges | Weights structurally correct |

Weight structural integrity confirmed:
- Embedding table: `shape=[152064, 5120]`, `dtype=fp16`, `min=-0.77, max=0.73`
- g_idx tensors: valid group indices (0..215 for `group_size=128`)
- 4-bit packed `qweight`: unpacked values show proper distribution (bell shape around 7)
- Model loading log: `18.02 GiB memory`, no errors

## Root Cause Hypothesis

**Likely: vLLM dev build regression in GPTQ/Marlin inference path on unified-memory (GB10/ARM) systems.**

Supporting evidence:
1. `quantization_config=None` in vLLM logs despite model having valid quantization config in `config.json`
2. Same weights work correctly on other systems (not verified — the model has 480K downloads)
3. The dev build is a nightly (`0.21.1rc1.dev277`) — pre-release quality, may have incomplete backends
4. ARM/SBSA architecture (GB10) uses different CUDA path than x86 — dev builds get less testing there
5. Output is too consistent for weight corruption — the model produces the same garbage tokens deterministically

## Verified Working Alternative: Nemotron-3-Nano-30B-A3B-FP8

See `references/nemotron-nano-30b-setup.md`. On the same GB10 hardware, with
the same vLLM build, Nemotron-3-Nano produces coherent output. The issue is
specific to the GPTQ-Int4 quantization path, not vLLM or GB10 in general.

## If You Encounter This

1. **Do NOT re-download weights** — they're fine. The issue is not corruption.
2. **Try a non-GPTQ version** of the model (AWQ, FP8, or non-quantized if the GPU fits it).
3. **Try an older stable vLLM release** (0.19.x or earlier) — the regression may be new in the dev build.
4. **Try a different model architecture** (Nemotron, Llama, Mistral) as a cross-check that vLLM inference works at all.
5. **Report to vLLM project** with the full config log output for debugging.

## Diagnosis Data Capture

If you need to report this issue, capture:

```bash
# 1. Full vLLM startup log
docker logs <container> 2>&1 > vllm-startup.log

# 2. A single inference attempt with verbose curl
curl -v --max-time 60 http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-32b","messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}' \
  2>&1 > inference-debug.log

# 3. vLLM version
docker exec <container> python3 -c "import vllm; print(vllm.__version__)"

# 4. GPU properties
docker exec <container> python3 -c "
import torch
p = torch.cuda.get_device_properties(0)
print(f'{p.name}, total_mem={p.total_memory/1024**3:.1f}GiB, arch={p.major}.{p.minor}')
"

# 5. Model config
cat /path/to/model/config.json | python3 -m json.tool
```
