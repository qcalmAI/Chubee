---
name: hermes-cleanup
title: Hermes Reset to Baseline
description: System maintenance — a READ-ONLY health check (disk, memory, containers, downloads, archives, log errors) plus a safe cleanup that strips ephemeral cruft (orphaned processes, stale locks, temp junk, SQLite bloat, wedged docker clients). Health diagnoses and points at cleanup or the human; neither touches config, skills, memories, credentials, or persistent data.
triggers:
  - "clean yourself up"
  - "reset to baseline"
  - "do a cleanup"
  - "health check or is the system healthy"
  - "is everything ok or system feels slow"
  - slow response / frequent crashes
  - recurring scheduled maintenance
---

# Hermes Reset to Baseline

This skill is the **system maintenance** umbrella. It has two arms, deliberately
separated:

- **Diagnose** — `scripts/health.sh`: a universal, READ-ONLY health check
  (disk, memory, processes, containers, downloads, archives, log errors). Never
  changes anything; silent when green; pings only on real problems.
- **Repair (safe)** — `scripts/hermes-cleanup.sh`: strips ephemeral cruft only.

`health.sh` reports problems and points at `hermes-cleanup.sh` for fixable
cruft, or at the human for anything involving deleting data. **That diagnose/
repair split is the safety model — never let the health arm mutate anything,
and never let cleanup touch non-ephemeral data.** Full rationale, the 7 health
categories, fault-injection testing, and the verify-before-destroy lesson (a
near-miss that almost deleted a 120B model): see
`references/health-and-verify-before-destroy.md`.

Cleanup strips ephemeral junk Hermes accumulates over hours — orphaned download
processes, stale HF locks, temp scripts, SQLite bloat, and (on Docker hosts)
wedged `docker compose`/`exec`/`cp` CLI clients from crashed prior sessions.
It **never** touches config, skills, memories, credentials, .env, auth, SSH
keys, plugins, cron, or hooks.

## Health check (diagnose arm)

```bash
bash ~/chubee/stack/health.sh          # full report (always prints)
bash ~/chubee/stack/health.sh --quiet  # silent unless problems (cron/watchdog)
bash ~/chubee/stack/health.sh --json   # machine-readable
```
Read-only; exit 0/1/2 = green/warnings/problems. Good as a `no_agent` cron
watchdog every 6h in `--quiet` mode (silent on healthy ticks). When building or
editing it, see the pitfalls in the references file — especially: use process
substitution not pipes (pipe-subshell loses findings → silent "all green"), and
TEST IT BY INJECTING FAULTS, not just by running it on a healthy system.

## How to run it

Everything lives in a single canonical script. **Do not paste shell blocks
inline** — long heredocs fail intermittently over SSH (confirmed: blocks die
at the first line boundary on flaky links). Always invoke the script:

```bash
bash ~/chubee/stack/hermes-cleanup.sh            # full run
bash ~/chubee/stack/hermes-cleanup.sh --dry-run  # preview, change nothing
```

If the host copy is missing (fresh machine / different host), the script also
ships with this skill at `scripts/hermes-cleanup.sh` — copy it to the host first:

```bash
cp "$(dirname "$(hermes skills inspect hermes-cleanup --path 2>/dev/null)")/scripts/hermes-cleanup.sh" ~/chubee/stack/ 2>/dev/null \
  || echo "Locate the skill dir and copy scripts/hermes-cleanup.sh manually"
bash ~/chubee/stack/hermes-cleanup.sh
```

### Flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Print every action, change nothing. **Always safe.** |
| `--no-vacuum` | Skip SQLite VACUUM — use when Hermes is under active load (VACUUM takes a brief exclusive lock). |
| `--reap-age N` | Age threshold in seconds for reaping orphaned docker clients (default 3600). Do **not** lower below ~600. |

## What it does (and why it is safe)

The script runs six **failure-isolated** steps — each logs and continues even
if it errors, so one broken step never aborts the rest. Exit code is always 0.

1. **Reap orphaned docker CLI clients** — kills wedged `docker cp|exec|compose|rm|run`
   and `cli-plugins/docker-compose` processes **older than `--reap-age` (default 1h)**,
   explicitly **excluding** `docker-proxy`, `dockerd`, `containerd`, and
   `docker_run.sh` (live container infra). This is an orphan reaper, **not** a
   docker-wide kill — a legitimate build's client is rarely >1h old and never
   orphaned. (Added after a session left 23 zombie clients that hung `docker
   logs`/`inspect` for 180s.)
2. **Kill orphaned HF downloads** — `hf download`, `snapshot_download`,
   `hf_hub_download`, `/tmp/dl_*` / `/tmp/download_*` scripts, and orphaned TUI
   slash workers. **Must run before step 4.**
3. **Purge temp** — `/tmp/hermes-snap-*.sh`, `hermes-cwd-*`, `hermes_bg_*`. Also removes the stale gateway log lock at `$HERMES_HOME/logs/gateways/default/lock` (safe — regenerated on next log write).
4. **Clear stale HF locks** — SAFETY-GATED: refuses to run unless step 2
   confirmed zero live downloads (clearing a live download's lock corrupts it).
   Fails **closed** (skips) rather than open.
5. **Clear regenerable caches** — `~/.hermes/image_cache/*`, `~/.hermes/cache/*`.
   Rebuilt on demand, no data loss.
6. **VACUUM SQLite** — `state.db`, `kanban.db`, `response_store.db`. Does a
   PASSIVE WAL checkpoint first and **skips** any DB that is busy, so it won't
   stall under load. Opt out entirely with `--no-vacuum`.

## Drift-proofing

The script **auto-discovers** `HERMES_HOME` and the HF cache via globs
(`/mnt/*/docker-volumes/*hf-cache`, `~/.cache/huggingface`, `$HF_HOME`, …)
instead of hardcoding paths. It degrades gracefully when `docker`/`sqlite3`
are absent and works with or without passwordless sudo. Moving the data volume
or running on a different host does not break it.

## ⚠️ Cron — guardrails before automating

The script is safe to run manually anytime. Before scheduling it:
- Run it manually a few times and confirm nothing legitimate gets clipped.
- For cron, pass `--no-vacuum` **or** confirm Hermes is idle at run time
  (VACUUM's exclusive lock can briefly block a concurrent write).
- The docker reaper's 1h age gate is the guardrail against killing live builds.
  Keep `--reap-age` ≥ 600. Do not run during a known long-running deploy.
- Highest-residual-risk line is the reaper regex (matches `ps args`); a
  long-lived process whose *arguments* contain `docker compose` could match.
  The age gate makes this nearly impossible for healthy processes, but flag it
  if you run tooling that shells out to docker for >1h.

## Maintaining this skill

If you change cleanup behavior, edit `scripts/hermes-cleanup.sh` (and the host
copy at `~/chubee/stack/hermes-cleanup.sh`) — **not** inline SKILL.md blocks.
The script is the single source of truth; this doc only explains it.
