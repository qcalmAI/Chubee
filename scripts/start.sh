#!/bin/bash
set -euo pipefail
cd ~/chubee/stack

if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

if ! mountpoint -q /mnt/chubee-backup; then
  echo "WARNING: backup drive not mounted; backups will fail."
fi

docker compose build litellm

docker compose up -d postgres
echo "Waiting for postgres to be healthy..."
WAIT=0
until docker compose ps postgres | grep -q healthy; do
  sleep 3
  WAIT=$((WAIT+3))
  if [ "$WAIT" -ge 180 ]; then
    echo "ERROR: postgres not healthy in 180s" >&2
    exit 1
  fi
done

docker exec -i postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -tc "SELECT 1 FROM pg_database WHERE datname='langfuse'" | grep -q 1 \
  || docker exec -i postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
       -c 'CREATE DATABASE langfuse;'

docker exec -i postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  < ~/chubee/migrations/001_initial.sql

docker compose up -d
sleep 5
docker compose ps
echo "vllm-super may take 20-25 min to become healthy on first start."
