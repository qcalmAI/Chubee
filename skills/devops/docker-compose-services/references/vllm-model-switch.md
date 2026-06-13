# vLLM Model Switch — Full Workflow

Swap the model served by the local vLLM instance (vllm-super on ChubeeAcer, port :8000).

## Step Sequence

### 1. Download New Weights

Use `hf download` with HF_TOKEN from `~/.hermes/.env`:

```bash
source /home/qcalmus/.hermes/.env
HF_TOKEN="$HF_TOKEN" hf download <org>/<model> \
  --local-dir /mnt/chubee-data/super-weights/<model-dir>
```

Model weights go under `/mnt/chubee-data/super-weights/` (mounted as `/weights:ro` in the compose container).

**Preferred quantization formats** (ordered by preference):
- **GPTQ-Int4** → vLLM uses Marlin kernel, best performance on this stack
- **AWQ** → also supported via Marlin
- **NVFP4** → NVIDIA native format, only for models released in this format (e.g., Nemotron Super)
- **FP16/BF16** → too large for 32B+ on 128GB; avoid unless necessary

### 2. Verify Image Architecture

```bash
docker inspect <image> --format '{{.Os}}/{{.Architecture}}'
# Confirm linux/arm64
```

### 3. Update Compose Service

Edit `~/chubee/stack/docker-compose.yml` (service `vllm-super`).

#### Flags That Change Per Model Architecture

| Flag | Nemotron (MoE, NVFP4) | Qwen2.5 (Dense, GPTQ-Int4) |
|------|----------------------|---------------------------|
| `--enforce-eager` | Required (MoE CUDA graph bugs) | Remove (CUDA graphs work fine) |
| `--mamba-ssm-cache-dtype` | `float16` (Mamba blocks) | Remove |
| `--reasoning-parser-plugin` | `/app/super_v3_reasoning_parser.py` | Remove |
| `--reasoning-parser` | `super_v3` | Remove |
| `--tool-call-parser` | `qwen3_coder` | `qwen3_coder` (same; Qwen2.5/3 share format) |
| `--kv-cache-dtype` | `fp8` ✓ | `fp8` ✓ |
| `--enable-auto-tool-choice` | ✓ | ✓ |
| `--max-model-len` | 131072 (YaRN extended) | 32768 (native Qwen2.5) |

#### Env Vars to Remove for Dense Models

| Variable | Purpose | Remove for Dense? |
|----------|---------|-------------------|
| `VLLM_NVFP4_GEMM_BACKEND` | NVFP4 kernel selection | Yes |
| `VLLM_USE_FLASHINFER_MOE_FP4` | MoE FP4 optimization | Yes |
| `VLLM_ALLOW_LONG_MAX_MODEL_LEN` | Extended context length | Optional, harmless |
| `VLLM_FLASHINFER_ALLREDUCE_BACKEND` | MoE allreduce backend | Optional, harmless |

#### Volume Mounts to Remove

- Reasoning parser plugin: `~/chubee/stack/litellm/super_v3_reasoning_parser.py:/app/...` — Nemotron-specific

#### Update Served Model Name

```yaml
--served-model-name qwen2.5-32b
```

#### Update .env Variables

```bash
# /home/qcalmus/chubee/stack/.env
VLLM_MAX_MODEL_LEN=32768   # Set to model's native context length
# VLLM_GPU_MEM_UTIL=0.80   # Usually keep at 0.80-0.85
```

### 4. Restart and Verify

```bash
cd ~/chubee/stack
docker compose up -d vllm-super

# Watch logs for model loading
docker logs vllm-super -f

# Wait for healthy status
docker compose -f ~/chubee/stack/docker-compose.yml ps vllm-super

# Test completion
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<served-model-name>",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 20
  }'
```

### 5. Update Hermes Config

The Hermes agent needs a custom provider pointing at the local vLLM instance:

```bash
# ~/.hermes/config.yaml changes:
model:
  default: <served-model-name>
  provider: custom:local

custom_providers:
  local:
    base_url: http://localhost:8000/v1
    api_key: ""
```

Settings take effect on next `/reset` or new session.

### 6. Preserving Old Weights

Do NOT delete the old model directory. Keep it on disk:
```
/mnt/chubee-data/super-weights/
├── NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/   # keep
└── Qwen2.5-32B-Instruct-GPTQ-Int4/              # current
```

To switch back, just change the compose command path and restart.

## Pitfalls

- **--enable-auto-tool-choice requires --tool-call-parser** in vLLM ≥0.21. Always specify both when enabling tool calling.
- **Invalid parser names**: vLLM has a fixed set of parsers. Run `vllm serve --help` to list available parsers; don't guess.
- **GPTQ vs NVFP4**: Don't mix kernel env vars. Remove `VLLM_NVFP4_GEMM_BACKEND` for GPTQ models — Marlin auto-detects.
- **The served model name** passed to Hermes must match --served-model-name exactly.
- **No bash in Alpine**: Healthchecks for the vLLM container itself use `curl` (Ubuntu-based image), but neighboring services may not.
- **Hermes config reversion on gateway crash/restart**: If the Hermes gateway crashes or restarts (container restart, OOM, host reboot), `model.default` and `model.provider` in `config.yaml` may revert to pre-switch values. The `custom_providers` section typically survives. Always verify config after any gateway disruption:
  ```bash
  head -6 ~/.hermes/config.yaml
  ```
  If reverted, re-apply the same patch. Root cause: the gateway may write runtime state back to config on shutdown, overwriting changes made since last gateway start.