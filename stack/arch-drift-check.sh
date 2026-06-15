#!/usr/bin/env bash
# arch-drift-check.sh — re-derive ChubeeAcer ground truth, compare to ARCHITECTURE.md.
# Prints a DRIFT report ONLY if something material changed; SILENT (empty stdout) otherwise.
# Does NOT edit the doc — it flags WHAT drifted; the agent writes the prose reconciliation.
# Canonical location: ~/chubee/stack/arch-drift-check.sh
# Invoked by cron via the thin wrapper ~/.hermes/scripts/arch-drift-check.sh

set -uo pipefail
DOC="${1:-$HOME/chubee/stack/ARCHITECTURE.md}"
report=""
add(){ report="${report}$1"$'\n'; }
[ -f "$DOC" ] && DOCTEXT="$(cat "$DOC")" || { echo "ARCH DOC MISSING at $DOC"; exit 0; }

# ── FACT: what vLLM actually serves (doc expects nemotron-nano-30b) ───────────
served="$(curl -s --max-time 8 http://localhost:8000/v1/models 2>/dev/null \
  | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); print(' '.join(sorted(m['id'] for m in d['data'])))
except Exception: print('UNREACHABLE')" 2>/dev/null)"
[ -z "$served" ] && served="UNREACHABLE"
case "$served" in
  *nemotron-nano-30b*) : ;;
  UNREACHABLE) add "• vLLM :8000 UNREACHABLE — down or restarting." ;;
  *) add "• vLLM now serving [$served] — doc expects nemotron-nano-30b. CHANGED." ;;
esac

# ── FACT: vLLM gpu-memory-utilization (.env vs doc header) ────────────────────
envutil="$(grep -m1 '^VLLM_GPU_MEM_UTIL=' "$HOME/chubee/stack/.env" 2>/dev/null | cut -d= -f2)"
[ -z "$envutil" ] && envutil="(unset)"
# doc header line: "gpu-memory-utilization: **0.60**"
docutil="$(echo "$DOCTEXT" | grep -oE 'gpu-memory-utilization: \*\*[0-9.]+\*\*' | head -1 | grep -oE '[0-9.]+')"
[ -n "$docutil" ] && [ "$envutil" != "$docutil" ] && \
  add "• gpu-util: .env=$envutil but doc says $docutil — MISMATCH."

# ── FACT: live KV cache token capacity (doc claims a specific figure) ─────────
kv="$(docker logs vllm-super 2>&1 | grep -oE 'GPU KV cache size: [0-9,]+ tokens' | tail -1 \
      | grep -oE '[0-9,]+' | tr -d ',')"
if [ -n "$kv" ]; then
  kvm=$(( kv / 1000000 ))   # millions
  # doc mentions "11.96M KV tokens"; flag if the live millions figure isn't in the doc
  echo "$DOCTEXT" | grep -qE "${kvm}\.[0-9]+M KV tokens|${kvm}M KV tokens" || \
    add "• live KV cache = ${kv} tokens (~${kvm}M) — not reflected in doc's KV figure."
fi

# ── FACT: Hermes default model+provider (report current on any change) ────────
hdef="$(docker exec hermes sh -c 'python3 -c "import yaml; c=yaml.safe_load(open(\"/opt/data/config.yaml\")); m=c.get(\"model\",{}); print(str(m.get(\"default\",\"?\"))+\" / \"+str(m.get(\"provider\",\"?\")))"' 2>/dev/null || echo '?')"
# Record last-seen value in a sidecar; alert when it changes between runs.
STATE="$HOME/chubee/stack/.drift-state"
prev="$(grep -m1 '^hermes_default=' "$STATE" 2>/dev/null | cut -d= -f2-)"
if [ -n "$hdef" ] && [ "$hdef" != "?" ] && [ -n "$prev" ] && [ "$hdef" != "$prev" ]; then
  add "• Hermes default model CHANGED: was [$prev] now [$hdef] — confirm intended."
fi
[ -n "$hdef" ] && [ "$hdef" != "?" ] && {
  grep -q '^hermes_default=' "$STATE" 2>/dev/null \
    && sed -i "s|^hermes_default=.*|hermes_default=$hdef|" "$STATE" \
    || echo "hermes_default=$hdef" >> "$STATE"
}

# ── FACT: expected container set (the 13 from the doc) ────────────────────────
running="$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ')"
for c in hermes hermes-dashboard vllm-super qdrant searxng crawl4ai kiwix \
         filebrowser wyoming-whisper wyoming-openwakeword wyoming-piper \
         portainer stirling-pdf; do
  echo "$running" | grep -qw "$c" || add "• expected container '$c' NOT running."
done

# ── FACT: Qdrant collections (doc §3b lists the knowledge collections) ────────
cols="$(curl -s --max-time 6 http://localhost:6333/collections 2>/dev/null \
  | python3 -c "import sys,json
try: print(' '.join(sorted(c['name'] for c in json.load(sys.stdin)['result']['collections'])))
except Exception: print('UNREACHABLE')" 2>/dev/null)"
[ -z "$cols" ] && cols="UNREACHABLE"
if [ "$cols" = "UNREACHABLE" ]; then
  add "• Qdrant :6333 UNREACHABLE."
else
  for col in chubee_skills chubee_crawl; do
    echo " $cols " | grep -q " $col " || add "• Qdrant collection '$col' MISSING (doc §3b expects it)."
  done
fi

# ── FACT: doc freshness ───────────────────────────────────────────────────────
lastver="$(echo "$DOCTEXT" | grep -oE 'Last verified: [0-9-]+' | head -1 | grep -oE '[0-9-]+')"
if [ -n "$lastver" ]; then
  age=$(( ( $(date +%s) - $(date -d "$lastver" +%s 2>/dev/null || echo "$(date +%s)") ) / 86400 ))
  [ "$age" -gt 30 ] && add "• doc 'Last verified' is ${age}d old — re-verify + bump."
fi

# ── Emit (silent on match) ────────────────────────────────────────────────────
if [ -n "$report" ]; then
  echo "ARCHITECTURE.md DRIFT DETECTED ($(date +%Y-%m-%d)):"
  printf '%s' "$report"
  echo "→ Reconcile ~/chubee/stack/ARCHITECTURE.md with the above and bump 'Last verified'."
fi
# else: no output, exit 0 — doc matches reality.
