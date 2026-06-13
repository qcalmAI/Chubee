# vLLM Upgrade: v0.21.x → v0.22.1+ for Qwen2.5 YaRN Context Scaling

## Why

Qwen2.5-32B has native `max_position_embeddings=32768` (32K). vLLM ≤0.21.x has **zero rope_scaling support** for Qwen2 models — the `--rope-scaling` flag and config.json edits are silently ignored. To get YaRN working on Qwen2, you must upgrade to vLLM ≥0.22.1 and use `--hf-overrides`.

## Quick Summary

| Step | Action | Duration |
|------|--------|----------|
| 1 | Stop vLLM container (frees ~100 GiB unified memory) | 5s |
| 2 | Build new image in tmux with `--vllm-ref v0.22.1` | 30-60 min |
| 3 | Update docker-compose.yml with `--hf-overrides` + `--max-model-len` | 2 min |
| 4 | Start container and verify | 3-5 min |

## Detailed Steps

### 0. Prune build cache

Failed builds leave 20+ GB of Docker build cache. Clear before starting:

```bash
docker buildx prune -f
```

### 1. Stop vLLM to free memory

```bash
cd ~/chubee/stack && docker compose stop vllm-super
```

Check memory freed: `free -h` should show >100 GiB available.

### 2. Build in tmux (bypasses Hermes 3-min SIGTERM)

```bash
cd ~/chubee/build/spark-vllm-docker

# Launch build in detached tmux session
tmux new-session -d -s vllm-build -x 120 -y 40 \
  "./build-and-copy.sh --vllm-ref v0.22.1 --build-jobs 4 2>&1 | tee /tmp/vllm-build-final.log"
```

**Monitor (max 3 min between checks):**
```bash
tail -3 /tmp/vllm-build-final.log
grep -oP '\[\K[0-9]+(?=/366)' /tmp/vllm-build-final.log | tail -1  # FlashInfer compile progress
wc -l < /tmp/vllm-build-final.log
```

Build phases: NCCL → FlashInfer (366 CUDA/CXX units, ~30-45 min) → vLLM (larger compilation) → runner image (~3 min). Report each status to user.

### 3. Update docker-compose.yml

Replace `--max-model-len "32768"` with YaRN flags in YAML array form:

```yaml
    command:
    - vllm
    - serve
    - /weights/Qwen2.5-32B-Instruct-GPTQ-Int4
    - --served-model-name
    - qwen2.5-32b
    - --trust-remote-code
    - --hf-overrides
    - '{"rope_parameters": {"factor": 8.0, "original_max_position_embeddings": 32768, "rope_theta": 1000000, "rope_type": "yarn"}}'
    - --max-model-len
    - "262144"
    - --kv-cache-dtype
    - fp8
```

### 4. Start vLLM

```bash
cd ~/chubee/stack
docker compose up -d --force-recreate vllm-super
# Wait for model loading (~2-5 min for 17 GB weights)
sleep 120
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

Expected: `"max_model_len": 262144`

### 5. Fix Hermes config

```yaml
# ~/.hermes/config.yaml
model:
  default: qwen2.5-32b
  context_length: 262144
```

**⚠️ WARNING:** `model.context_length` is **GLOBAL** — caps ALL models. Remove when swapping back to DeepSeek (1M native).

## Critical: Torch CUDA Install on ARM64 (DGX Spark / GB10)

**Root cause of `libtorch_cuda.so: cannot open shared object file`:**

The upstream `spark-vllm-docker` Dockerfile contains two `uv pip install torch` commands (base + runner stages), both pointing at the **stable** PyTorch index:
```
--index-url https://download.pytorch.org/whl/cu130
```

The stable `cu130` index **has no aarch64 wheels** for PyTorch. On ARM64 (GB10/GH200), this causes `uv` to resolve to `torch==2.10.0+cpu` (CPU-only). The vLLM wheel was compiled against CUDA torch, so `libtorch_cuda.so` is missing at import time.

### The Fix

Change BOTH torch install lines (base stage ~line 53, runner stage ~line 343) to use the **nightly** index:

```bash
# In Dockerfile — BOTH locations:
uv pip install torch torchvision torchaudio triton \
  --index-url https://download.pytorch.org/whl/nightly/cu130
```

The nightly index carries aarch64 `+cu130` wheels (versions: `2.12.0.dev*+cu130` and `2.13.0.dev*+cu130`). Example output after fix:
```
torch==2.13.0.dev20260603+cu130
torchaudio==2.11.0.dev20260606+cu130
torchvision==0.28.0.dev20260606+cu130
```

### Prevent the Runner Stage from Downgrading to CPU Torch (Issue #265)

Even with the nightly index, subsequent `uv pip install` calls (wheel install, ray/fastsafetensors) may re-resolve torch to the CPU version. Pin torch in EVERY post-torch install step using `--override`:

```dockerfile
# Wheel install step
RUN ... \
    PINNED_TORCH=$(python3 -c "import torch; print(torch.__version__)") && \
    echo "torch==${PINNED_TORCH}" > /tmp/wheel-override.txt && \
    uv pip install /workspace/wheels/*.whl --override /tmp/wheel-override.txt

# Ray/fastsafetensors step
RUN ... \
    PINNED_TORCH=$(python3 -c "import torch; print(torch.__version__)") && \
    echo "torch==${PINNED_TORCH}" > /tmp/ray-override.txt && \
    uv pip install ray[default] fastsafetensors --override /tmp/ray-override.txt
```

This pattern is from [albond/DGX_Spark_Qwen3.5-122B-A10B-AR-INT4](https://github.com/albond/DGX_Spark_Qwen3.5-122B-A10B-AR-INT4/blob/master/install.sh) and fixes the "nightly torch version drift" that causes the `uv` resolver to pick CPU torch when CUDA dependencies conflict.

### Verifying the fix

After the image is built, verify in a non-GPU context (the version suffix is reliable even without a GPU):

```bash
docker run --rm vllm-node:latest python3 -c "
import torch
version = torch.__version__
print(version)
assert '+cu' in version, f'FAIL: CPU torch ({version})'
print(f'OK: CUDA torch ({version})')
"
```

If this shows `+cu`, the image will work with `--gpus all` at runtime.

## Prebuilt Wheel Alternative

If a prebuilt wheel matching CUDA 13.2 + aarch64 exists at `eugr/spark-vllm-docker` releases:

```bash
WHEEL_URL=$(curl -sf "https://api.github.com/repos/eugr/spark-vllm-docker/releases/tags/prebuilt-vllm-current" \
  | python3 -c "import json,sys; data=json.load(sys.stdin); print([a['browser_download_url'] for a in data['assets'] if a['name'].startswith('vllm-') and 'aarch64' in a['name']][0])")
wget -O wheels/vllm-aarch64.whl "$WHEEL_URL"
```

**Known failure:** `libtorch_cuda.so: cannot open shared object file` — the prebuilt wheel was compiled against a different torch/CUDA version than what the runner image has. Source build is more reliable on this system.

## Verification

```bash
# vLLM reports correct context
curl -s http://localhost:8000/v1/models | python3 -c "import json,sys; m=json.load(sys.stdin)['data'][0]; print(f'{m[\"id\"]}: max_model_len={m[\"max_model_len\"]}')"

# Hermes accepts model  
hermes chat -q "Say hello" -m qwen2.5-32b
```