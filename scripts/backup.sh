#!/bin/bash
set -euo pipefail
set -a; . ~/chubee/stack/.env; set +a

LOGFILE="/mnt/chubee-data/logs/backup-$(date +%Y%m%d).log"
mkdir -p /mnt/chubee-data/logs /mnt/chubee-data/snapshots

{
echo "=== Backup started: $(date) ==="

if ! mountpoint -q /mnt/chubee-backup; then
  echo "ERROR: backup drive not mounted. Aborting."
  /usr/local/bin/chubee-alert "Backup FAILED" "drive not mounted" "high" || true
  exit 1
fi

docker exec -i postgres pg_dumpall -U "$POSTGRES_USER"   | gzip > /mnt/chubee-data/snapshots/pg_dumpall-$(date +%Y%m%d).sql.gz

ls -1t /mnt/chubee-data/snapshots/pg_dumpall-*.sql.gz | tail -n +8 | xargs -r rm -f

restic backup   /mnt/chubee-data ~/chubee   --exclude=/mnt/chubee-data/logs   --exclude=/mnt/chubee-data/corpora   --exclude=/mnt/chubee-data/ollama-models   --exclude=/mnt/chubee-data/super-weights   --tag=nightly

restic forget --keep-daily=7 --keep-weekly=4 --keep-monthly=12 --prune

echo "=== Backup complete: $(date) ==="
} >> "$LOGFILE" 2>&1
