#!/usr/bin/env bash
# hermes-cleanup.sh — strip ephemeral cruft without touching persistent state.
# Design goals: drift-proof (auto-discovers paths), universal (degrades when
# tools/paths absent), and FAILURE-ISOLATED (one broken step never aborts the
# rest). The only hard gate is a SAFETY gate: HF locks are cleared ONLY after
# downloads are confirmed dead.
#
# Usage:
#   bash hermes-cleanup.sh              # run
#   bash hermes-cleanup.sh --dry-run    # show what would happen, change nothing
#   bash hermes-cleanup.sh --no-vacuum  # skip SQLite VACUUM (use under load)
#   bash hermes-cleanup.sh --reap-age 3600   # docker-orphan age threshold (s)
#
# Exit code is ALWAYS 0 unless invoked wrong — cleanup is best-effort by design.
#
# CANONICAL COPY lives at ~/chubee/stack/hermes-cleanup.sh on the host (ChubeeAcer).
# This copy travels with the skill so it is portable to any machine. Keep them
# in sync; if they diverge, the host copy is authoritative for ChubeeAcer.

set -uo pipefail   # NOT -e: we deliberately continue past individual failures

DRY_RUN=0; DO_VACUUM=1; REAP_AGE=3600
for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;;
  --no-vacuum) DO_VACUUM=0 ;;
  --reap-age) shift; REAP_AGE="${1:-3600}" ;;
  --reap-age=*) REAP_AGE="${a#*=}" ;;
esac; done

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
run(){ if [ "$DRY_RUN" = 1 ]; then log "DRY: $*"; else eval "$*"; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }
# Run a step in isolation: log + continue no matter what it returns.
step(){ local name="$1"; shift; log "── $name"; "$@" || log "   (step '$name' returned non-zero — continuing)"; }

# sudo only if available AND passwordless; otherwise fall back to plain.
SUDO=""; if have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi
priv(){ if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi; }

# ── Auto-discovery (drift-proofing) ───────────────────────────────────────────
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# HF cache: prefer env, else docker volume, else common fallbacks. First hit wins.
discover_hf_cache(){
  local c
  for c in "${HF_HOME:-}" "${HUGGINGFACE_HUB_CACHE:-}" \
           /mnt/*/docker-volumes/*hf-cache /mnt/*/*hf-cache \
           "$HOME/.cache/huggingface"; do
    [ -n "${c:-}" ] && [ -d "$c" ] && { echo "$c"; return; }
  done
}
HF_CACHES=$(discover_hf_cache 2>/dev/null)

# ── Step 1: reap orphaned docker CLI clients (age+state gated, exclusion list) ─
reap_docker_orphans(){
  have docker || { log "   docker absent — skip"; return 0; }
  # Match only client verbs that wedge; exclude live infra. Gate on age > REAP_AGE.
  local pids
  pids=$(ps -eo pid,etimes,stat,args 2>/dev/null | awk -v age="$REAP_AGE" '
    $2 > age \
    && /docker (cp|exec|compose|rm|run )|cli-plugins\/docker-compose/ \
    && !/docker-proxy|dockerd|containerd|docker_run\.sh|hermes-cleanup|awk/ \
    { print $1 }')
  if [ -z "$pids" ]; then log "   no orphaned docker clients > ${REAP_AGE}s"; return 0; fi
  log "   reaping orphaned docker clients: $(echo $pids | tr '\n' ' ')"
  for p in $pids; do run "priv kill -9 $p 2>/dev/null"; done
}

# ── Step 2: kill orphaned HF download processes ───────────────────────────────
kill_downloads(){
  local pat="hf download|snapshot_download|hf_hub_download"
  local pids; pids=$(pgrep -f "$pat" 2>/dev/null)
  if [ -n "$pids" ]; then
    log "   killing downloads: $(echo $pids|tr '\n' ' ')"
    for p in $pids; do run "priv kill -9 $p 2>/dev/null"; done
  else log "   no live downloads"; fi
  # Catch-all script patterns + orphaned TUI workers (regenerated on demand)
  for p in "^python3 /tmp/dl_" "^python3 /tmp/download_" "^bash /tmp/download_" "tui_gateway.slash_worker"; do
    run "pkill -f '$p' 2>/dev/null || true"
  done
}
downloads_clear(){ [ -z "$(pgrep -f 'hf download|snapshot_download|hf_hub_download' 2>/dev/null)" ]; }

# ── Step 3: temp files ────────────────────────────────────────────────────────
purge_temp(){
  run "rm -f /tmp/hermes-snap-*.sh /tmp/hermes-cwd-*.txt /tmp/hermes_bg_*.pid /tmp/hermes_bg_*.log /tmp/hermes_bg_*.exit 2>/dev/null || true"
  run "rm -f '$HERMES_HOME'/logs/gateways/default/lock 2>/dev/null || true"
}

# ── Step 4: stale HF locks — SAFETY-GATED on downloads being dead ──────────────
clear_hf_locks(){
  if ! downloads_clear; then
    log "   ABORT lock-clear: downloads still alive (would corrupt a live transfer)"
    return 0
  fi
  [ -z "$HF_CACHES" ] && { log "   no HF cache discovered — skip"; return 0; }
  local c
  for c in $HF_CACHES; do
    [ -d "$c/hub/.locks" ] && run "priv rm -rf '$c/hub/.locks' 2>/dev/null || true"
    run "priv find '$c' -name '*.lock' -type d -exec rm -rf {} + 2>/dev/null || true"
  done
}

# ── Step 5: regenerable caches ────────────────────────────────────────────────
clear_caches(){
  [ -d "$HERMES_HOME" ] || { log "   no HERMES_HOME — skip"; return 0; }
  run "rm -rf '$HERMES_HOME'/image_cache/* '$HERMES_HOME'/cache/* 2>/dev/null || true"
}

# ── Step 6: VACUUM (opt-out; WAL-checkpoint guard before exclusive lock) ───────
vacuum_dbs(){
  [ "$DO_VACUUM" = 1 ] || { log "   --no-vacuum set — skip"; return 0; }
  have sqlite3 || { log "   sqlite3 absent — skip"; return 0; }
  local db
  for db in "$HERMES_HOME"/state.db "$HERMES_HOME"/kanban.db "$HERMES_HOME"/response_store.db; do
    [ -f "$db" ] || continue
    # Best-effort WAL checkpoint first; if DB is busy, skip the exclusive VACUUM.
    if [ "$DRY_RUN" = 1 ]; then log "DRY: VACUUM $db"; continue; fi
    sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1
    if sqlite3 "$db" "VACUUM;" 2>/dev/null; then
      log "   vacuumed $(basename "$db") -> $(ls -lh "$db"|awk '{print $5}')"
    else
      log "   $(basename "$db") busy — skipped VACUUM"
    fi
  done
}

# ── Pipeline ──────────────────────────────────────────────────────────────────
log "hermes-cleanup start (dry_run=$DRY_RUN vacuum=$DO_VACUUM reap_age=${REAP_AGE}s)"
log "discovered: HERMES_HOME=$HERMES_HOME  HF_CACHES=[${HF_CACHES:-none}]"
step "1. reap docker orphans"  reap_docker_orphans
step "2. kill downloads"       kill_downloads
step "3. purge temp"           purge_temp
step "4. clear HF locks"       clear_hf_locks
step "5. clear caches"         clear_caches
step "6. vacuum sqlite"        vacuum_dbs

log "── verification"
have free && free -h | head -2
log "live downloads: $(pgrep -fc 'hf download|snapshot_download' 2>/dev/null || echo 0)"
log "temp scripts:   $(ls /tmp/hermes-*.sh 2>/dev/null | wc -l)"
have docker && log "containers up:  $(docker ps -q 2>/dev/null | wc -l)"
# Report VRAM usage
have nvidia-smi && {
    read -r used total <<<[N/A], [N/A]
    free=0
    log "VRAM usage: MiB used / MiB total (MiB free)"
{'$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits)"\n    free=$((total - used))\n    log': 'RAM usage: ${used}MiB used / ${total}MiB total (${free}MiB free)'}
log "hermes-cleanup done (best-effort; exit 0)"
exit 0
