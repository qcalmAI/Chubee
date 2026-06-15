#!/bin/bash
# Sync hermes config FROM ~/.hermes/ INTO ~/chubee/hermes-config/
# Hermes data is owned by UID 10000, so read via docker exec
set -e

CHUBEE="/opt/data/home/chubee/hermes-config"
CONTAINER=hermes-dashboard

# Config + personality
docker exec  cat /opt/data/config.yaml > "/config.yaml"
docker exec  cat /opt/data/SOUL.md > "/SOUL.md"

# Cron jobs
docker exec  cat /opt/data/cron/jobs.json > "/cron/jobs.json"

# Memories
docker exec  cat /opt/data/memories/MEMORY.md > "/memories/MEMORY.md" 2>/dev/null || true
docker exec  cat /opt/data/memories/USER.md > "/memories/USER.md" 2>/dev/null || true

echo 'Synced hermes config -> chubee/hermes-config/'
