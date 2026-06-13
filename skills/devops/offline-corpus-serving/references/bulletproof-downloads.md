# Bulletproof downloads: detached + resumable + verified

Long downloads/builds kept dying this session. Root cause and the simple,
durable fix:

## Why jobs die, and the fix

Hermes' background-process watcher SIGTERMs (-15) tracked `terminal(background=
true)` jobs after `TERMINAL_LIFETIME_SECONDS` (default 300s; bumped to 7200=2h
on ChubeeAcer in the agent .env). Sequential multi-item loops are especially
exposed — the whole loop is ONE tracked job, so it dies partway.

**Fix — launch fully detached so the watcher has no child to kill:**
```bash
# tmux (most reliable, fully detached):
tmux new-session -d -s job 'bash /tmp/dl.sh > /tmp/dl.log 2>&1'
tmux ls; tail -5 /tmp/dl.log     # poll the log (max 3-min intervals per user pref)

# setsid alternative:
setsid bash -c 'long_cmd > /tmp/job.log 2>&1' &
```
A detached job has **no time limit** — the 2h watcher window is irrelevant to it.
So the rule is simply: **expected >~3 min → detach.** No timeout tuning needed.

## "-15 is a lie" — trust the artifact, not the notification

Hermes' own bg wrapper uses `nohup`, so the child `wget` often SURVIVES the
SIGTERM and keeps running even though the completion notification reports
`exit -15`. **Don't trust -15** — check the real state: `ls -lh` the output file,
`tail` the log, or `pgrep -af wget`. Several times this session the "failed" job
had actually finished or was still progressing.

## Resumable + verified = bulletproof through simplicity

1. **`wget -c`** (resume). Any interruption — power, network, a cleanup kill —
   resumes from the exact byte on re-run. Re-running is the safe recovery.
2. **Verify before trust.** After download: local bytes == remote
   `Content-Length` AND format magic bytes (ZIM = `b'ZIM\x04'`; gzip = `1f 8b`;
   safetensors = valid header). Only register/use VERIFIED files.
3. **Idempotent.** Re-running does nothing for complete files (wget -c sees
   they're done) and finishes incomplete ones. No PID files, no locks, no state
   to corrupt. If unsure, just run it again.

This needs no progress daemon and no timeout tuning — detached + resumable +
verify is the entire reliability story.

## Interaction with hermes-cleanup.sh

Cleanup Step 2 kills download processes (`pkill -f wget` etc.). A detached
download IS therefore killable by a cleanup run — correct behavior (cleanup
kills strays), and harmless because `wget -c` resumes. Implication: **don't run
cleanup mid-download unless you mean to pause it.** Verify-before-register means
a cleanup-killed partial can't be mistaken for complete.

## Picking the right ZIM variant / size

Check the real remote size before committing:
```bash
curl -sIL "<url>" | grep -i content-length | tail -1 | tr -dc '0-9'  # bytes
```
For Wikipedia/Wikivoyage: `nopic` (text-only, smaller, best for RAG/LLM) vs
`maxi` (with images, better for travel browsing). DevDocs are per-tool ZIMs
(~1-30 MB each), no bundled "all" — pick the tools you want.
