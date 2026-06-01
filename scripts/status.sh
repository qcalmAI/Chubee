#!/bin/bash
echo "=== Containers ==="
docker compose -f ~/chubee/stack/docker-compose.yml ps --format "table {{.Service}}\t{{.Status}}"
echo
echo "=== Disk ==="
df -h /mnt/chubee-data /mnt/chubee-backup
echo
echo "=== GPU ==="
nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used --format=csv,noheader 2>/dev/null || echo "(unified memory: nvidia-smi memory query N/A; check vLLM logs for KV cache)"
echo
echo "=== Last backup ==="
ls -t /mnt/chubee-data/logs/backup-*.log 2>/dev/null | head -1 | xargs tail -3
