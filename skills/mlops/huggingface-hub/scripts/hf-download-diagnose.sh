#!/bin/bash
# hf-download-diagnose.sh
# Run this BEFORE any HF model download to verify readiness.
# Usage: bash <(skill_view name=huggingface-hub file_path=scripts/hf-download-diagnose.sh)
#   OR:  path/to/scripts/hf-download-diagnose.sh [model-name]
set -euo pipefail

MODEL="${1:-}"  # optional specific model to check

echo "=== HF Token Check ==="
if [ -z "${HF_TOKEN:-}" ]; then
  echo "  WARN: HF_TOKEN not set in environment"
  if [ -f ~/.hermes/.env ]; then
    echo "  Found ~/.hermes/.env — sourcing..."
    source ~/.hermes/.env
  fi
fi

python3 -c "
from huggingface_hub import HfApi, HfFolder
try:
    token = HfFolder().get_token()
    u = HfApi().whoami(token=token)
    print(f'  TOKEN OK — {u[\"name\"]} ({u.get(\"email\",\"?\")})')
except Exception as e:
    print(f'  TOKEN INVALID/EXPIRED: {e}')
" 2>&1 || echo "  TOKEN CHECK FAILED"

echo ""
echo "=== Zombie Processes ==="
count=$(ps aux | grep -cE "hf download.*Qwen|snapshot_download.*Qwen|wget.*safetensors")
if [ "$count" -gt 1 ]; then
  echo "  WARN: Found stale download processes:"
  ps aux | grep -E "hf download.*Qwen|snapshot_download.*Qwen|wget.*safetensors" | grep -v grep
else
  echo "  OK: No stale download processes"
fi

echo ""
echo "=== Stale Lock Files ==="
CACHE_DIRS=(
  "/mnt/chubee-data/docker-volumes/vllm-hf-cache/hub"
  "$HOME/.cache/huggingface/hub"
)
for dir in "${CACHE_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    locks=$(find "$dir -name '*.lock' -mmin +5 2>/dev/null | wc -l)"
    if [ "$locks" -gt 0 ]; then
      echo "  WARN: $locks stale locks in $dir"
      echo "  Fix: find \"$dir\" -name '*.lock' -mmin +5 -delete"
    else
      echo "  OK: No stale locks in $dir"
    fi
  fi
done

echo ""
echo "=== Connectivity ==="
curl -s -o /dev/null -w "  HF Hub: %{http_code} (%{time_total}s)\n" \
  "https://huggingface.co" --max-time 5 || echo "  FAIL: cannot reach huggingface.co"

echo ""
echo "=== Quick Fix Commands ==="
echo "  sudo rm -rf /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--Qwen--Qwen2.5-32B-Instruct-GPTQ-Int4/"
echo "  sudo rm -rf /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/.locks/models--Qwen--Qwen2.5-32B-Instruct-GPTQ-Int4/"
echo "  pkill -f 'hf download.*Qwen' 2>/dev/null; pkill -f 'wget.*safetensors' 2>/dev/null"
echo ""

if [ -n "$MODEL" ]; then
  echo "=== Model Cache ==="
  find "$HOME/.cache/huggingface/hub" -maxdepth 1 -name "models--*${MODEL//\//--}*" -type d 2>/dev/null
fi