# Building vLLM from Source (GB10/ARM64)

## The Problem

`./build-and-copy.sh --vllm-ref <tag>` compiles CUDA/C++ kernel code for 30-60
minutes. Hermes' `terminal(background=true)` tracks the child PID and sends
SIGTERM after ~3 minutes — killing the build.

## Solution: tmux (fully detached)

```bash
cd ~/chubee/build/spark-vllm-docker
tmux new-session -d -s vllm-build -x 120 -y 40 \
  "./build-and-copy.sh --vllm-ref v0.22.1 --build-jobs 4 2>&1 | tee /tmp/vllm-build.log"

# Monitor — MAX 3 MINUTES between checks:
tmux capture-pane -t vllm-build -p | tail -5
tail -3 /tmp/vllm-build.log

# FlashInfer compile progress:
grep -oP '\[[0-9]+(?=/366)' /tmp/vllm-build.log | tail -1

# Attach interactively:
tmux attach -t vllm-build
```

The tmux session has NO parent-child relationship to Hermes. No SIGTERM propagation.

## Alternative: setsid + trap SIGTERM

```bash
terminal(background=True, command="cd /path && setsid -w bash -c 'trap \"\" TERM; ./build-and-copy.sh ...'")
```
Limitation: if Hermes background session handle expires before build completes
(>5 min), a race window opens. Prefer tmux for builds over 10 min.

## Prebuilt Wheel Alternative

If prebuilt wheels matching your CUDA/PyTorch stack exist (check releases),
download them:

```bash
wget -O wheels/vllm-aarch64.whl <release-url>
docker build -t vllm-node:latest --build-arg BUILD_JOBS=4 --build-arg TORCH_CUDA_ARCH_LIST="12.1a" .
```

## aarch64 CUDA PyTorch Gotcha (CRITICAL)

On aarch64 (GB10), the **stable** PyTorch index `download.pytorch.org/whl/cu130`
has NO aarch64 CUDA wheels. `uv pip install torch ... --index-url .../whl/cu130`
silently resolves to `torch==X+cpu`. The vLLM `_C` extension compiled against
CUDA torch → container dies at startup with:
```
libtorch_cuda.so: cannot open shared object file
```

**Fix — use the NIGHTLY index:**
```dockerfile
RUN uv pip install torch torchvision torchaudio triton \
    --index-url https://download.pytorch.org/whl/nightly/cu130
```
Leave versions unpinned — nightly uses `.devYYYYMMDD+cu130` strings.

Verify after build:
```bash
docker run --rm --gpus all vllm-node:latest python3 -c \
  "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
# Expect: 2.13.0.dev...+cu130 13.0 True
```

**Pin live torch after install** to prevent later `uv pip install` from
downgrading to CPU:
```bash
PINNED_TORCH=$(python3 -c "import torch;print(torch.__version__)")
echo "torch==${PINNED_TORCH}" > /tmp/ov.txt
uv pip install <wheels> --override /tmp/ov.txt
```

## Prune Build Cache

Failed builds leave 20+ GB of Docker cache:
```bash
docker buildx prune -f
```
