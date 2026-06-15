User wants build/process check intervals at max 3 minutes — never set longer intervals.
§
Before mutating a live service: prove broken with READ-ONLY probes first. Reproduce exact failing request. Verify git diff, bash history, on-disk state — don't trust garbled summaries.
§
CRITICAL — Stale background processes from prior sessions corrupt model files in /mnt/chubee-data/super-weights/. Before any model-file operation, ALWAYS kill stale downloads: `ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null` then a second pass. Never mix safetensor shards from different download sessions — all 5 must come from the same byte-for-byte source or vLLM fails with "mixed quantization" errors.
§
ChubeeAcer (100.65.206.99): headless Acer ARM64. Source: ~/hermes-agent. Config: ~/.hermes→/opt/data. Services on compose: gateway, dashboard (v0.16.0). The hermes container stays stopped (UID clash). `docker compose up -d --force-recreate` for restart. Tailscale SSH: qcalmus@chubeeacer. Local vLLM at 172.17.0.1:8000 (Qwen, Nemotron), Ollama 127.0.0.1:11434 (GLM vision). Primary: OpenRouter. Startup 3-4min.
§
Do NOT modify SOUL.md or core config files unless explicitly directed. The user wants those left alone.
§
Stale lock cleanup: hermes-cleanup skill handles ~/.hermes/logs/gateways/*/lock and other stale lock files.
§
Finances: /mnt/chubee-data/personal-docs/Finances/. Roth IRA (3127): $44.5K contribs (roth-ira-contributions.csv), ~$124K growth. Scale AI $4.9K/biwk→Vg 0577. Reimb $1.2K/mo→8837. VA $3.9K/mo→8829→Vg VA 4654. Scale ISO: 20K options @$2.162, 0% vested (scale-options.csv). Crypto cold silent. 401k $1,020/biwk 70/30.
§
Secret redaction OFF (`security.redact_secrets: false`) — user's explicit preference. No truncation of tokens/secrets in tool calls.
§
When native tools missing or container down: LOAD hermes-config-ops skill FIRST. Covers all 3 config bugs (TERMINAL_ENV, platform_toolsets, session caching) + UID disaster recovery. Recovery file: ~/chubee/stack/RECOVERY.md (host-readable when container dead). Never docker restart without --force-recreate.