#!/usr/bin/env bash
# health.sh — universal, READ-ONLY system health check.
#
# PHILOSOPHY (do not violate):
#   1. READ-ONLY. NEVER changes anything — no delete, no kill, no restart, no
#      config edit. Looks, judges, reports. Repair is a separate, explicit step
#      (hermes-cleanup.sh for safe ephemeral repair; the human for anything else).
#   2. UNIVERSAL IN CATEGORIES, AUTO-DISCOVERING IN SPECIFICS. Fixed dimensions
#      (disk, memory, processes, containers, downloads, archives, errors) but it
#      DISCOVERS what to check (every container, every data dir) — no hardcoded
#      service names, so new services/wikis/models are covered for free.
#   3. CONTEXT-AWARE. Knows vLLM reserves memory, so it measures AVAILABLE not
#      USED. Health that cries wolf gets ignored — worse than no health.
#   4. QUIET WHEN GREEN. --quiet prints NOTHING and exits 0 when all is well;
#      speaks only when something is wrong (watchdog pattern, cron-friendly).
#
# IMPLEMENTATION NOTE: every discovery loop uses `while read ... done < <(cmd)`
# (process substitution), NOT `cmd | while read`. A piped while runs in a
# SUBSHELL, so findings recorded inside it are LOST — that made an early version
# silently report "all green" with a corrupt file present. Do not reintroduce pipes.
#
# USAGE:
#   bash health.sh            # full human report (always prints)
#   bash health.sh --quiet    # silent unless problems (cron/watchdog mode)
#   bash health.sh --json     # machine-readable summary
# EXIT: 0 healthy, 1 warnings, 2 problems.

set -uo pipefail
MODE="full"
for a in "$@"; do case "$a" in
  --quiet) MODE="quiet";; --json) MODE="json";;
esac; done

DISK_WARN_PCT=${DISK_WARN_PCT:-85}
DISK_CRIT_PCT=${DISK_CRIT_PCT:-93}
MEM_AVAIL_WARN_MB=${MEM_AVAIL_WARN_MB:-2048}
ZOMBIE_AGE=${ZOMBIE_AGE:-3600}
DATA_DIRS=${DATA_DIRS:-"/mnt/chubee-data $HOME/.hermes"}

have(){ command -v "$1" >/dev/null 2>&1; }

PROBS=0; WARNS=0
REPORT=""
note(){  # note SEV category message
  local sev="$1" cat="$2" msg="$3"
  [ "$sev" = PROB ] && PROBS=$((PROBS+1)) || WARNS=$((WARNS+1))
  REPORT="${REPORT}$(printf '  [%s] %-11s %s' "$sev" "$cat" "$msg")"$'\n'
}

# ===== 1. DISK =====
check_disk(){
  have df || return
  local pct avail mnt
  while read -r pct avail mnt; do
    [ -z "$pct" ] && continue
    if   [ "$pct" -ge "$DISK_CRIT_PCT" ]; then note PROB disk "Filesystem $mnt is ${pct}% full (CRITICAL)."
    elif [ "$pct" -ge "$DISK_WARN_PCT" ]; then note WARN disk "Filesystem $mnt is ${pct}% full."
    fi
  done < <(df -P 2>/dev/null | awk 'NR>1 && $1!~/tmpfs|udev|overlay/ {gsub("%","",$5); print $5, $4, $6}')
}

# ===== 2. MEMORY (context-aware: AVAILABLE, not used) =====
check_memory(){
  have free || return
  local avail; avail=$(free -m | awk '/^Mem:/{print $7}')
  [ -z "$avail" ] && return
  [ "$avail" -lt "$MEM_AVAIL_WARN_MB" ] && \
    note WARN memory "Only ${avail}MB RAM available (high 'used' from vLLM reservation is normal; this is the real free figure)."
}

# ===== 3. WEDGED DOCKER CLIENTS =====
check_processes(){
  have ps || return
  local n
  n=$(ps -eo etimes,args 2>/dev/null | awk -v age="$ZOMBIE_AGE" \
      '$1>age && /docker (cp|exec|compose|rm)/ && !/docker-proxy|dockerd|containerd|health\.sh|awk/' | wc -l)
  [ "$n" -gt 0 ] && note WARN processes "$n wedged docker CLI process(es) >${ZOMBIE_AGE}s old (run cleanup to reap)."
}

# ===== 4. CONTAINERS (auto-discovered) =====
check_containers(){
  have docker || return
  local name status pol
  while IFS=$'\t' read -r name status; do
    [ -z "$name" ] && continue
    case "$status" in
      *Restarting*) note PROB containers "Container '$name' is restart-looping ($status)." ;;
      *unhealthy*)  note PROB containers "Container '$name' is unhealthy ($status)." ;;
      *Exited*)
        pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null)
        { [ "$pol" = always ] || [ "$pol" = unless-stopped ]; } && \
          note WARN containers "Container '$name' Exited but set to restart ($status)."
        ;;
    esac
  done < <(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
}

# ===== 5. DOWNLOADS — healthy & intentional =====
check_downloads(){
  local d f z magic
  for d in $DATA_DIRS; do
    [ -d "$d" ] || continue
    while read -r f; do
      [ -z "$f" ] && continue
      note WARN downloads "Orphaned partial/temp file: $f (incomplete download?)."
    done < <(find "$d" -maxdepth 3 \( -name "*.part" -o -name "*.tmp" -o -name "*.crdownload" \
             -o -name "wget-log*" -o -name "*.aria2" \) 2>/dev/null)
    while read -r z; do
      [ -z "$z" ] && continue
      magic=$(head -c 4 "$z" 2>/dev/null)
      [ "$magic" = "ZIM"$'\x04' ] || note PROB downloads "ZIM failed magic-byte check (corrupt/truncated): $z"
    done < <(find "$d" -maxdepth 2 -name "*.zim" 2>/dev/null)
  done
}

# ===== 6. ARCHIVE INTEGRITY (header magic only — cheap) =====
check_archives(){
  local d g m
  for d in $DATA_DIRS; do
    [ -d "$d" ] || continue
    while read -r g; do
      [ -z "$g" ] && continue
      m=$(head -c 2 "$g" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')
      [ "$m" = "1f8b" ] || note PROB archives "Archive missing gzip magic (corrupt/not-gzip): $g"
    done < <(find "$d" -maxdepth 2 -name "*.tar.gz" 2>/dev/null)
    # Deep verification (gzip -t CRC, tar -t, shard counts) is DELIBERATELY excluded:
    # too slow, and "5 of 17 shards" passes gzip -t but is useless — needs a human.
  done
}

# ===== 7. ERROR SIGNALS IN LOGS (read-only sampling) =====
# IGNORE_LOG_PATTERNS: chronic-but-benign noise to exclude so health doesn't cry
# wolf. Verified benign on ChubeeAcer: s6-log lock contention fires continuously
# (60k+ times/18h) while the gateway works perfectly — a supervision quirk, not a
# fault. Add patterns (pipe-separated, grep -E) only after CONFIRMING harmless.
IGNORE_LOG_PATTERNS=${IGNORE_LOG_PATTERNS:-"s6-log: fatal: unable to lock"}
check_errors(){
  have docker || return
  local name errs
  while read -r name; do
    [ -z "$name" ] && continue
    errs=$(docker logs --since 10m "$name" 2>&1 \
           | grep -vE "$IGNORE_LOG_PATTERNS" \
           | grep -ciE "panic:|fatal|out of memory|CUDA error|Traceback" 2>/dev/null)
    [ "${errs:-0}" -gt 5 ] && note WARN errors "Container '$name' logged ${errs} error lines in last 10m."
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
}

check_disk; check_memory; check_processes; check_containers
check_downloads; check_archives; check_errors

rc=0; [ "$WARNS" -gt 0 ] && rc=1; [ "$PROBS" -gt 0 ] && rc=2

case "$MODE" in
  json) printf '{"problems":%d,"warnings":%d,"exit":%d}\n' "$PROBS" "$WARNS" "$rc" ;;
  quiet)
    if [ "$rc" -ne 0 ]; then
      echo "SYSTEM HEALTH: ${PROBS} problem(s), ${WARNS} warning(s) — $(date '+%Y-%m-%d %H:%M')"
      printf '%s' "$REPORT"
      [ "$PROBS" -gt 0 ] && echo "  → Ephemeral cruft (wedged procs, stale locks, temp): bash ~/chubee/stack/hermes-cleanup.sh"
      echo "  → Deleting data/files: decide by hand. health.sh never auto-fixes."
    fi ;;
  *)
    if [ "$rc" -eq 0 ]; then echo "SYSTEM HEALTH: all green ✓  ($(date '+%Y-%m-%d %H:%M'))"
    else
      echo "SYSTEM HEALTH: ${PROBS} problem(s), ${WARNS} warning(s)  ($(date '+%Y-%m-%d %H:%M'))"
      printf '%s' "$REPORT"
      echo
      echo "Safe repairs (ephemeral only): bash ~/chubee/stack/hermes-cleanup.sh"
      echo "Data/file decisions: human judgment required — health.sh never deletes or kills."
    fi ;;
esac
exit $rc
