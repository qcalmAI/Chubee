#!/bin/bash
set -e
ENV_FILE="$HOME/.hermes/.env"
HF_TOKEN=$(grep -oP 'HF_TOKEN=\K.*' "$ENV_FILE" | head -1)
echo "Token length: ${#HF_TOKEN}"
exec hf download Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --local-dir /mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --force-download \
  --token "$HF_TOKEN" 2>&1