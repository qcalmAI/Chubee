User wants build/process check intervals at max 3 minutes — never set longer intervals.
§
DIAGNOSIS: On working/live services, run READ-ONLY probes FIRST to prove broken before mutating. Reproduce exact failing request and bisect params. Verify git diff/status, bash history, on-disk state before believing garbled auto-summaries or empty session_search.
§
CRITICAL — Stale background processes from prior sessions corrupt model files in /mnt/chubee-data/super-weights/. Before any model-file operation, ALWAYS kill stale downloads: `ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null` then a second pass. Never mix safetensor shards from different download sessions — all 5 must come from the same byte-for-byte source or vLLM fails with "mixed quantization" errors.
§
Chubee runs Dockerized on ChubeeAcer (100.65.206.99, ARM64 GB10). Source: ~/hermes-agent (fork chubee-custom, upstream=NousResearch/hermes-agent). Config: ~/.hermes→/opt/data (NOT git-tracked). Containers: hermes (gateway, currently STOPPED), hermes-dashboard (LIVE: dashboard+gateway, use `docker exec hermes-dashboard`). v0.16.0. UID-10000 permission fix: see docker-compose-services skill. Tailscale SSH: qcalmus@chubeeacer. After any self-update: verify http://100.65.206.99:9119→200 and ss -tlnp|grep 9119 shows 0.0.0.0 not 127.0.0.1. NEVER docker restart after build — rm -f + up -d. Startup takes 3-4min.
§
EXECUTION: Obvious task = 1-2 calls. Don't build when only queued — confirm intent first. Ignore out-of-band bg notifications mid-task.
§
Do NOT modify SOUL.md or core config files unless explicitly directed. The user wants those left alone.
§
Kiwix welcome.html uses suggest-API title-index search. Always use suggest `path` field for URLs (never construct from `value`). decodeHtml() on values/labels. nginx:8181 injects dark CSS; Kiwix on 8180. Alpine healthchecks: 127.0.0.1 not localhost.
§
Stale log lock at ~/.hermes/logs/gateways/default/lock must be cleared by hermes-cleanup skill alongside other stale lock cleanup (Tier 1).