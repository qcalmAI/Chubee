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
    exit 0
fi
COMMIT_MSG="Auto-backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git commit -m "$COMMIT_MSG"
git push origin main
