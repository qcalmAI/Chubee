User wants build/process check intervals at max 3 minutes — never set longer intervals.
§
Before mutating a live service: prove broken with READ-ONLY probes first. Reproduce exact failing request. Verify git diff, bash history, on-disk state — don't trust garbled summaries.
§
Model-file safety: kill stale downloads before any model op (`ps aux | grep model-0000 | awk '{print $2}' | xargs -r kill -9` ×2 passes). Never mix safetensor shards from different sessions. User preserves models as offline "trophy" tarballs — self-contained archives isolated from running services. Worried open-source models may become illegal.
§
ChubeeAcer (100.65.206.99): ARM64/GB10, 119.7GiB unified memory. SSH: qcalmus@chubeeacer. Hermes source ~/hermes-agent (fork: qcalmAI/Chubee.git), config ~/.hermes→/opt/data. Stack repo ~/chubee (qcalmAI/chubee-stack.git). vLLM :8000 (Nemotron Nano 30B), Ollama :11434 (GLM vision). Primary: OpenRouter. Only hermes-dashboard running (hermes stopped). Model trophies: Qwen2.5-32B (15GB) + Nemotron-Super-120B (75GB) in /mnt/chubee-data/. Startup 3-4min.
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