#!/usr/bin/env bash
# Runs inside container for cron (HOME=/opt/data/home). Tries SSH first;
# falls back to direct curl checks inside container.
set -uo pipefail
DOC="${HOME:-/opt/data/home}/chubee/stack/ARCHITECTURE.md"
report=""
add(){ report="${report}$1"$'\n'; }

# Try SSH to host for full script
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
  qcalmus@localhost "bash /home/qcalmus/chubee/stack/arch-drift-check.sh" 2>/dev/null \
  && exit 0

# SSH failed — do limited checks from inside container
[ -f "$DOC" ] && DOCTEXT=$(cat "$DOC") || { echo "ARCH DOC MISSING"; exit 0; }

# vLLM models via curl to localhost:8000
served=$(curl -s --max-time 8 http://localhost:8000/v1/models 2>/dev/null \
  | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); print(' '.join(sorted(m['id'] for m in d['data'])))
except Exception: print('UNREACHABLE')" 2>/dev/null)
[ -z "$served" ] && served="UNREACHABLE"
case "$served" in
  *nemotron-nano-30b*) : ;;
  UNREACHABLE) add "vLLM :8000 UNREACHABLE — down or restarting." ;;
  *) add "vLLM now serving [$served] — doc expects nemotron-nano-30b." ;;
esac

# Qdrant collections via curl
cols=$(curl -s --max-time 6 http://localhost:6333/collections 2>/dev/null \
  | python3 -c "import sys,json
try: print(' '.join(sorted(c['name'] for c in json.load(sys.stdin)['result']['collections'])))
except Exception: print('UNREACHABLE')" 2>/dev/null)
[ -z "$cols" ] && cols="UNREACHABLE"
[ "$cols" = "UNREACHABLE" ] && add "Qdrant :6333 UNREACHABLE."

# doc freshness
lastver=$(echo "$DOCTEXT" | grep -oE "Last verified: [0-9-]+" | head -1 | grep -oE "[0-9-]+")
if [ -n "$lastver" ]; then
  age=$(( ( $(date +%s) - $(date -d "$lastver" +%s 2>/dev/null || echo $(date +%s)) ) / 86400 ))
  [ "$age" -gt 30 ] && add "doc Last verified is ${age}d old — re-verify + bump."
fi

if [ -n "$report" ]; then
  echo "ARCHITECTURE.md DRIFT DETECTED ($(date +%Y-%m-%d)):"
  printf "%s" "$report"
  echo "(Limited scan — ran inside container. GPU-util, containers, KV cache, Hermes config not checked.)"
  echo "Full reconciliation requires agent to run checks via its SSH tools."
fi