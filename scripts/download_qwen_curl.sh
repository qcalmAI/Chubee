#!/bin/bash
set -e

# Kill any leftover curl processes for this model first
pkill -f "model-0000.*safetensors" 2>/dev/null || true

WEIGHTS_DIR="/mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4"
mkdir -p "$WEIGHTS_DIR"
rm -f "$WEIGHTS_DIR"/model-0000*.safetensors

# Get HF token
ENV_FILE="$HOME/.hermes/.env"
if [ -f "$ENV_FILE" ]; then
  HF_TOKEN=$(grep -oP 'HF_TOKEN=\K.*' "$ENV_FILE" | head -1)
else
  echo "ERROR: .env not found"
  exit 1
fi

SHARDS=(
  "model-00001-of-00005.safetensors"
  "model-00002-of-00005.safetensors"
  "model-00003-of-00005.safetensors"
  "model-00004-of-00005.safetensors"
  "model-00005-of-00005.safetensors"
)

for shard in "${SHARDS[@]}"; do
  echo ""
  echo "=== $shard ==="
  # Download to a temp file first, then atomically rename
  curl -sL -o "$WEIGHTS_DIR/$shard.tmp" \
    -H "Authorization: Bearer $HF_TOKEN" \
    "https://huggingface.co/Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4/resolve/main/$shard" \
    --connect-timeout 30 --max-time 1800 \
    -w "HTTP %{http_code}, Size: %{size_download} bytes\n"
  
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "CURL failed with exit code $rc for $shard"
    rm -f "$WEIGHTS_DIR/$shard.tmp"
    exit $rc
  fi
  
  # Verify the file is valid
  size=$(stat --format=%s "$WEIGHTS_DIR/$shard.tmp" 2>/dev/null || echo 0)
  if [ "$size" -lt 100000000 ]; then
    echo "File too small ($size bytes) - likely corrupt"
    rm -f "$WEIGHTS_DIR/$shard.tmp"
    exit 1
  fi
  
  # Rename atomically
  mv "$WEIGHTS_DIR/$shard.tmp" "$WEIGHTS_DIR/$shard"
  echo "  Complete: $shard ($(du -h "$WEIGHTS_DIR/$shard" | cut -f1))"
done

echo ""
echo "ALL SHARDS DOWNLOADED AND VERIFIED"
ls -lh "$WEIGHTS_DIR"/model-0000*.safetensors