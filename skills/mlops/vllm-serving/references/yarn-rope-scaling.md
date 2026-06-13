# YaRN RoPE Scaling via Model Config

Qwen2.5, Llama 3.x, and Mistral models support YaRN (Yet another RoPE extensioN)
scaling to extend the effective context window beyond the model's native
`max_position_embeddings`.

## vLLM Version Support

- **vLLM < 0.25**: Qwen2 model code has ZERO references to `rope_scaling`.
  The config field is silently ignored. Only native `max_position_embeddings`
  (32,768) is reliable for Qwen2. Llama-family models DO support config.json
  rope_scaling.
- **vLLM 0.22+**: Use `--hf-overrides` — injects YaRN parameters into HF config
  in memory before the model code reads it, bypassing Qwen2's missing support.

Verify: `docker exec <vllm-container> grep -r "rope_scaling" /usr/local/lib/python3.12/dist-packages/vllm/model_executor/models/qwen2.py`

## Method A: `--hf-overrides` (v0.22+, RECOMMENDED)

Works for ALL model architectures. No persistent edits to weights dir.

```bash
vllm serve /weights/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --hf-overrides '{"rope_parameters": {"factor": 8.0, "original_max_position_embeddings": 32768, "rope_theta": 1000000, "rope_type": "yarn"}}' \
  --max-model-len 262144
```

In YAML array form (safest — no quoting gotchas):
```yaml
command:
  - vllm; - serve; - /weights/Qwen2.5-32B-Instruct-GPTQ-Int4
  - --hf-overrides
  - '{"rope_parameters": {"factor": 8.0, "original_max_position_embeddings": 32768, "rope_theta": 1000000, "rope_type": "yarn"}}'
  - --max-model-len; - "262144"
```

## Method B: config.json (vLLM 0.22+, Llama-family)

Edit model's `config.json` before vLLM starts:
```json
"max_position_embeddings": 32768,
"rope_scaling": {
  "type": "yarn",
  "factor": 2.0,
  "original_max_position_embeddings": 32768
},
```
Then set `VLLM_MAX_MODEL_LEN=65536` and restart.
**Does NOT work for Qwen2 on vLLM < 0.25.**

## Method C: Legacy `--rope-scaling` flag (v0.11–0.21, deprecated)

```bash
vllm serve /weights/... \
  --rope-scaling '{"rope_type":"yarn","factor":2.0,"original_max_position_embeddings":32768}' \
  --max-model-len 65536
```
Field name: `rope_type` (flag parser) vs `type` (config.json). Include both for
compatibility. **Does NOT work for Qwen2 on vLLM < 0.25.**

## Verification

```bash
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0].get('max_model_len','?'))"
```

## Docker Compose Quoting Pitfall

When `command:` is a YAML string, single quotes leak as literals:
```yaml
# WRONG — literal single quotes in the arg:
command: >
  --hf-overrides '{"rope_parameters": {...}}'
```
Use YAML array form (safest):
```yaml
command:
  - --hf-overrides
  - '{"rope_parameters": {...}}'
```

Single-quoted YAML string escape for `--hf-overrides`:
```yaml
command: 'vllm serve ... --hf-overrides ''{...}'' --max-model-len ...'
```
`''` in YAML produces one `'` in output.

## `--force-download` Reverts config.json

`hf download <model> --local-dir <dir> --force-download` overwrites `config.json`
with stock from Hub. YaRN scaling silently lost. Always re-apply edits or verify:
`python3 -c "import json; c=json.load(open('config.json')); print(c.get('rope_scaling'))"`

## Quality Notes

- **2× scaling (64K)**: Well-tested, minimal degradation.
- **4× scaling (128K)**: Quality degrades — model wasn't trained at these lengths.
- **8× scaling (256K)**: Pushing limits; only for models with native long-context.
- For reliable long-context beyond 2×, prefer native support (Nemotron-3-Nano at
  256K+ native via Mamba, Mistral 24B at 128K).

## GB10 Context Sizing Reference (Qwen2.5-32B-GPTQ-Int4)

KV bytes/token: 2 × 64 layers × 8 KV heads × 128 head_dim × 1 byte (FP8) = 128 KB/token

| Context | YaRN Factor | KV Cache | + Weights (17 GiB) | Headroom (128 GiB) |
|---------|------------|----------|--------------------|--------------------|
| 32K (native) | — | ~4 GiB | ~21 GiB | 107 GiB |
| 128K | 4× | ~16 GiB | ~33 GiB | 95 GiB |
| 256K | 8× | ~32 GiB | ~49 GiB | 79 GiB ✅ sweet spot |
| 512K | 16× | ~64 GiB | ~81 GiB | 47 GiB ✅ practical max |
| 1M | 32× | ~128 GiB | ~145 GiB | ❌ doesn't fit |

Recommendation for Qwen2.5-32B on GB10: **256K (factor=8)** safe, **512K (factor=16)** practical max.
