# Health + Cleanup: the diagnose/repair split, and verify-before-destroy

This system has **two arms**, deliberately separated. Conflating them is how a
maintenance pass causes the damage it was meant to prevent.

| Arm | Script | Rule |
|-----|--------|------|
| **Diagnose** | `scripts/health.sh` | READ-ONLY. Never deletes, kills, restarts, or edits. Looks, judges, reports. |
| **Repair (safe)** | `scripts/hermes-cleanup.sh` | Touches ONLY ephemeral cruft (orphan procs, stale locks, temp, SQLite bloat). Regenerable, best-effort, exit 0. |
| **Repair (risky)** | the human | Anything that deletes data/files or restarts a working service. health/cleanup never do this. |

`health.sh` POINTS at `hermes-cleanup.sh` for fixable cruft, and at the human for
everything else. That handoff is the whole architecture.

## The core principle (earned the hard way, repeatedly)

Across this work, **every near-miss was an ACTION taken on insufficient
verification — never a detection.** Detecting is safe; acting is where damage
happens. Therefore:

- **Health is read-only by design.** It has nothing to leak, lock, or corrupt
  because it never touches anything. That is its entire safety model — don't
  add a `--fix` that does more than delegate to already-proven-safe cleanup ops.
- **Never auto-act on DATA.** Disk-full is a safe universal signal; *which files
  to delete* is human judgment. "Remove duplicate archives, keep the smaller"
  is exactly the heuristic that nearly destroyed a model (below).

## ⚠️ Verify-before-destroy: the 120B archive near-miss

Two files looked like duplicates of the same model:
`NVIDIA-Nemotron-3-Super-120B-...tar` (75G) and `...tar.gz` (21G). The obvious
"reclaim space" move — keep the small compressed one, delete the big one —
would have **destroyed the only complete copy.** Verification revealed:

- `.tar` (75G) = COMPLETE: all 17 shards + config.json + tokenizer + index.
- `.tar.gz` (21G) = CORRUPT FRAGMENT: only 5 of 17 shards, no configs — a
  half-written archive from an interrupted/killed gzip. **Useless**, but it
  passes `gzip -t` (the bytes it has are valid) so a naive check trusts it.

**Rule before deleting ANY archive/model copy you believe is redundant:**
1. List contents of BOTH (`tar -tzf` / `tar -tf`) — run in the background, these
   are slow on multi-GB files and will time out a foreground call.
2. Count shards and confirm the full set (`model-NNNNN-of-MMMMM`, all present)
   AND that config/tokenizer/index files exist.
3. Only delete the copy proven INCOMPLETE. `gzip -t` passing is NOT proof of
   completeness — it only proves the bytes present are uncorrupted, not that all
   the bytes are there.

## health.sh: what it checks (7 auto-discovered categories)

disk · memory(available, not used) · wedged-docker-procs · containers(restart/
unhealthy/exited) · downloads(orphan partials + ZIM magic) · archives(gzip magic) ·
log error-spikes. It DISCOVERS targets (every container, every data dir) rather
than hardcoding service names — new services/wikis/models are covered for free.

Run it: `bash ~/chubee/stack/health.sh` (full), `--quiet` (silent unless problems,
cron mode), `--json`. Wired as a cron watchdog (`no_agent`, every 6h, quiet) so it
stays silent on healthy ticks and only pings when something is wrong.

## Pitfalls hit while building health.sh (do not reintroduce)

1. **Pipe-subshell blindness (CRITICAL).** `find ... | while read; do note ...; done`
   runs the loop in a SUBSHELL — findings recorded inside are LOST, so the script
   silently reported "all green" with a planted corrupt file present. **Always use
   process substitution:** `while read ... done < <(cmd)`. Caught only by
   FAULT-INJECTION testing (plant a fake corrupt file, assert it's detected) — not
   by reading the code. Test health checks by injecting faults, not just by running.
2. **`gzip -l` / `gzip -t` hang the pass.** Both read the ENTIRE stream; on a 15GB
   archive that hangs for minutes. For a fast health pass, check the 2-byte gzip
   magic (`1f 8b`) only. Deep CRC verification is a separate, on-demand step.
3. **False-alarm chronic noise.** First real run flagged 595 "fatal" lines from the
   Hermes gateway — which turned out to be s6-log lock contention firing 60k+ times
   over 18h while the gateway worked perfectly. A health check that cries wolf gets
   ignored, defeating its purpose. Confirm an error is real (count since container
   start, check the service actually works) BEFORE trusting it; add verified-benign
   patterns to `IGNORE_LOG_PATTERNS`.
4. **Memory false alarm.** On unified-memory/vLLM hosts, `used` RAM looks ~96% full
   (the vLLM reservation). Measure `available` (free -m col 7), never `used`.

## Interaction with cleanup (the user flagged this)

`hermes-cleanup.sh` Step 2 kills download processes and Step 4 clears HF locks. A
download running detached (tmux/setsid) IS killable by cleanup's `pkill -f wget` —
that is correct behavior (cleanup's job is to kill strays), and harmless when the
download uses `wget -c` (resumes on next run). Implication: **don't run cleanup
mid-download unless you mean to pause it.** Verify-before-register (size == remote
content-length, magic bytes) protects against a cleanup-killed partial being
mistaken for complete.
