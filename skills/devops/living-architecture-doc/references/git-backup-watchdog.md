# Git Backup Watchdog — Silent-on-Clean Cron Pattern

Push persistent state to a remote Git repo nightly. The script is a classic
watchdog: **silent when clean, loud only on push or failure**.

## Script (`backup-to-git.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="/opt/data"
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "[$(date)] Not a git repo at $REPO_DIR - aborting" >&2
    exit 1
fi
cd "$REPO_DIR"
git add -A
if git diff-index --quiet HEAD --; then
    exit 0                    # SILENT — no changes, cron delivers nothing
fi
COMMIT_MSG="Auto-backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git commit -m "$COMMIT_MSG"
git push origin main          # stdout = commit message → delivered on push
```

Key properties:
- `exit 0` with NO stdout when clean → cron delivers nothing → user sees nothing.
- Non-empty stdout on push → cron delivers the commit message.
- Non-zero exit on failure → cron delivers an error alert.

## Cron job

```yaml
schedule: "0 2 * * *"
script: "backup-to-git.sh"
no_agent: true
enabled_toolsets: ["file", "terminal"]
profile: default
deliver: origin
```

`no_agent: true` means the scheduler runs the script directly — no LLM, no
tokens burned on a mechanical push. `deliver: origin` sends output to the
originating conversation (only on push or failure).

## Prerequisites

1. Git repo initialized at `/opt/data` (or wherever persistent state lives).
2. `.gitignore` excludes runtime noise (`.env`, `*.lock`, `cron/output/`,
   `gateway.pid`, `cron/jobs.json`, logs, caches).
3. SSH deploy key with write access added to the GitHub repo.
4. `ssh-keyscan github.com >> ~/.ssh/known_hosts` inside the container (or
   `GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"`).

## Path conventions (ChubeeAcer)

- Container path: `/opt/data` (bind-mount of host `~/.hermes/`)
- Cron script path: `backup-to-git.sh` → resolves to `/opt/data/scripts/backup-to-git.sh`
- Host user can't write to `~/.hermes/` (UID 10000 owns it) — use
  `docker exec hermes-dashboard` to create/edit files inside the mount
