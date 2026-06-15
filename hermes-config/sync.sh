#!/bin/bash
# Sync hermes config FROM ~/.hermes/ INTO ~/chubee/hermes-config/
# Run this before git commit to capture latest state
set -e

CHUBEE="/opt/data/home/chubee/hermes-config"
HERMES="/opt/data/home/.hermes"

# Config + personality
cp "/config.yaml" "/"
cp "/SOUL.md" "/"

# Cron jobs
cp "/cron/jobs.json" "/cron/"

# Memories
cp "/memories/MEMORY.md" "/memories/" 2>/dev/null || true
cp "/memories/USER.md" "/memories/" 2>/dev/null || true

# Scripts
cp "/scripts/"*.py "/scripts/" 2>/dev/null || true
cp "/scripts/"*.sh "/scripts/" 2>/dev/null || true

# Skills (custom only)
rsync -a --delete "/skills/dogfood/" "/skills/dogfood/" 2>/dev/null || true
rsync -a --delete "/skills/research/youtube-textbook/" "/skills/research/youtube-textbook/" 2>/dev/null || true

echo 'Synced hermes config -> chubee/hermes-config/'
