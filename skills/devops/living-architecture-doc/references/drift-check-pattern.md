# Drift-Check Watchdog — Annotated Template

A silent-on-match detector that compares live system state to an architecture
doc. Empty stdout = no drift = cron sends nothing. Bulleted stdout = drift = the
agent reconciles the doc and notifies. Copy this and swap the FACT blocks for the
system you're documenting.

```bash
#!/usr/bin/env bash
# arch-drift-check.sh — re-derive ground truth, compare to ARCHITECTURE.md.
# Prints a DRIFT report only if something material changed; SILENT otherwise.
# Does NOT edit the doc — it flags WHAT drifted; the agent writes the prose.

set -uo pipefail
DOC="${1:-$HOME/<stack>/ARCHITECTURE.md}"
report=""
add(){ report="${report}$1"$'\n'; }
[ -f "$DOC" ] && DOCTEXT="$(cat "$DOC")" || DOCTEXT=""

# ── FACT: what is the server actually serving? ────────────────────────────────
served="$(curl -s --max-time 8 http://localhost:8000/v1/models 2>/dev/null \
  | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); print(' '.join(sorted(m['id'] for m in d['data'])))
except Exception: print('UNREACHABLE')" 2>/dev/null)"
[ -z "$served" ] && served="UNREACHABLE"
case "$served" in
  *<expected-model>*) : ;;
  UNREACHABLE) add "• server :8000 UNREACHABLE — down or restarting." ;;
  *) add "• now serving [$served] — doc says <expected-model>. CHANGED." ;;
esac

# ── FACT: app's configured default ────────────────────────────────────────────
hdef="$(python3 -c "import yaml,os
c=yaml.safe_load(open(os.path.expanduser('~/.hermes/config.yaml')))
m=c.get('model',{}); print(str(m.get('default','?'))+' / '+str(m.get('provider','?')))" 2>/dev/null || echo '?')"
case "$hdef" in
  <expected-default>*) : ;;
  *) add "• default = [$hdef] — doc says <expected-default>. ROUTING CHANGED." ;;
esac

# ── FACT: must-stay-empty invariant (e.g. legacy config dict) ─────────────────
pdict="$(python3 -c "import yaml,os
c=yaml.safe_load(open(os.path.expanduser('~/.hermes/config.yaml')))
print(len(c.get('providers',{}) or {}))" 2>/dev/null || echo '?')"
[ "$pdict" != "0" ] && [ "$pdict" != "?" ] && \
  add "• legacy providers dict has $pdict entries (should be 0) — misroute risk."

# ── FACT: measured perf number present in doc tables? (bare-number match!) ─────
conc="$(docker logs <container> 2>&1 | grep -oE 'Maximum concurrency for [0-9,]+ tokens per request: [0-9.]+x' | tail -1)"
if [ -n "$conc" ]; then
  cnum="$(echo "$conc" | grep -oE '[0-9.]+x$' | tr -d 'x')"   # strip unit
  echo "$DOCTEXT" | grep -qF "$cnum" || \                      # grep -qF bare number
    add "• measured '$conc' not in doc tables — numbers may be stale."
fi

# ── FACT: expected container set ──────────────────────────────────────────────
running="$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ')"
for c in <container-a> <container-b>; do
  echo "$running" | grep -qw "$c" || add "• expected container '$c' NOT running."
done

# ── FACT: doc freshness ───────────────────────────────────────────────────────
lastver="$(echo "$DOCTEXT" | grep -oE 'Last verified: [0-9-]+' | head -1 | grep -oE '[0-9-]+')"
if [ -n "$lastver" ]; then
  age=$(( ( $(date +%s) - $(date -d "$lastver" +%s 2>/dev/null || echo 0) ) / 86400 ))
  [ "$age" -gt 30 ] && add "• doc 'Last verified' is ${age}d old — re-verify + bump."
fi

# ── Emit (silent on match) ────────────────────────────────────────────────────
if [ -n "$report" ]; then
  echo "ARCHITECTURE.md DRIFT DETECTED ($(date +%Y-%m-%d)):"
  printf '%s' "$report"
  echo "→ Reconcile the doc with the above and bump 'Last verified'."
fi
# else: no output, exit 0 — doc matches reality.
```

## Cron wiring recap

- Canonical script lives with the stack; a thin wrapper in `~/.hermes/scripts/`
  does `exec bash "$HOME/<stack>/arch-drift-check.sh" "$@"`. Cron's `script`
  field references just the wrapper FILENAME (paths must be relative to
  `~/.hermes/scripts/` — absolute/`~` paths are rejected).
- `enabled_toolsets: [terminal, file]`, schedule `0 9 * * *`.
- Validate the detector is silent against a freshly-written-truthful doc BEFORE
  scheduling — a detector that false-positives on day one trains the user to
  ignore it.

## Gotchas proven in practice

- **Unicode vs ascii unit:** doc `82.25×` won't match log `82.25x`. Strip the unit,
  match the bare number with `grep -qF`.
- **Comma formatting:** `262,144` vs `262144`. Normalize before comparing.
- **Reasoning-model smoke test:** unrelated but co-occurs — a too-small `max_tokens`
  returns `content:null` with a populated `reasoning` field; not a failure.
