#!/bin/bash
set -e
# Extract HF_TOKEN from .env
ENV_FILE="$HOME/.hermes/.env"
if [ -f "$ENV_FILE" ]; then
  HF_TOKEN=$(grep -oP 'HF_TOKEN=\K.*' "$ENV_FILE" | head -1)
else
  echo "ERROR: .env file not found"
  exit 1
fi
echo "Token length: ${#HF_TOKEN}"
exec hf download Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --local-dir /mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --token "$HF_TOKEN" 2>&1