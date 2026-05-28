#!/bin/bash
set -euo pipefail
source ~/chubee/stack/.env 2>/dev/null || true

SERVICES="postgres qdrant n8n open-webui litellm langfuse searxng vllm-super"
FAILED=""

cd ~/chubee/stack
for svc in $SERVICES; do
  STATUS=$(docker compose ps "$svc" --format json 2>/dev/null | python3 -c     "import sys,json; d=json.load(sys.stdin); print(d.get('"State"','"unknown"'))" 2>/dev/null || echo "missing")
  if [ "$STATUS" != "running" ]; then
    FAILED="$FAILED $svc($STATUS)"
  fi
done

if [ -n "$FAILED" ]; then
  /usr/local/bin/chubee-alert "Service Down" "Unhealthy:$FAILED" "high" || true
fi
