---
name: hermes-config-ops
description: Diagnose and fix the three main Hermes configuration bugs that break native tools (terminal, file, patch). Also covers the architecture of desktop-to-headless connection, session-tool-caching gotcha, and the real HA latency bottleneck.
version: 1.0.0
tags: [hermes, config, troubleshooting, tools, homeassistant, boondoggle]
---

# Hermes Config Ops: The Boondoggle

## The Three Config Bugs That Break Native Tools

All three must be present AND a fresh session opened for tools to work:

### 1. TERMINAL_ENV=ssh in .env (GH #29186)
- **Symptom:** Terminal/file tools silently fail — no error, just not available
- **Cause:** `TERMINAL_ENV` env var overrides `config.yaml` at process level. If `.env` has `TERMINAL_ENV=ssh`, the gateway boots SSH backend with no host/user configured
- **Fix:** Remove the line from `/opt/data/.env`: `sed -i '/^TERMINAL_ENV/d' /opt/data/.env`
- **Verification:** `grep TERMINAL_ENV /opt/data/.env` should return nothing

### 2. platform_toolsets.cli expanded list (GH #22601/#22573)
- **Symptom:** Native tools (terminal, read_file, write_file, patch, search_files) silently missing from toolset
- **Cause:** `platform_toolsets.cli` must be `['hermes-cli']`. An expanded list (e.g. `['hermes-cli', 'hermes-discord', 'hermes-google_workspace', ...]`) drops native tools
- **Fix:** Set in config.yaml: `platform_toolsets.cli: ['hermes-cli']`
- **Verification:** Dashboard Config → General section → platform_toolsets → cli → should show ONLY `hermes-cli`

### 3. UID Clash in Docker
- **Symptom:** `hermes` container stays stopped, `/restart` doesn't fix it
- **Cause:** Host UID doesn't match container's expected user. A simple restart inherits the bad config
- **Fix:** `docker compose up -d --force-recreate` — recreates the container from scratch with correct UID mapping
- **NOTE:** `hermes gateway stop && hermes gateway start` also works on ChubeeAcer if docker compose is configured

## The Session-Tool-Caching Gotcha

**Config changes don't take effect in the current session.** Hermes reads config at session birth. You MUST start a `/new` session for config changes to be picked up — even after restarting the gateway and dashboard containers.

## Desktop-to-Headless Architecture

- **Desktop app** (native Electron) runs its own `hermes dashboard` process by default
- To mirror sessions: point desktop app at ChubeeAcer's dashboard (http://100.65.206.99:9119)
- Dashboard backend connection = shared sessions, shared config, shared everything
- This is NOT about model provider endpoints — it's about the dashboard/gateway backend
- Dashboard needs auth enabled: `DASHBOARD_USERNAME` + `DASHBOARD_PASSWORD` in `.env`

## HA Latency: The Real Bottleneck

HA tool calls are ~50ms. The 30-second perceived latency is NOT from tools. It's:

| Phase | Time |
|-------|------|
| LLM Call #1 (OpenRouter queue + DeepSeek inference) | 15-25s |
| Tool execution (aiohttp → HA REST API) | ~50ms |
| LLM Call #2 (tool result → response) | 5-10s |
| **Total** | **20-35s** |

**Actual fixes for speed:**
1. Faster model (Claude Sonnet, GPT-4o Mini, Gemini Flash) — shaves 5-15s
2. Shorter context (compress memory, trim history) — shaves 2-5s
3. Local model (vLLM at 172.17.0.1:8000) — eliminates network hop entirely

Connection pooling on the HA tool is already done. Don't chase HA-side optimizations — the bottleneck is the LLM.

## The Five-Layer Debugging Checklist

When Hermes is broken, debug in THIS order. Don't skip layers:

1. **Install layer:** Does `hermes --version` run? `which hermes`? `source ~/.zshrc` if not.
2. **Config layer:** Does `hermes config path` point to the right profile? Is `.env` being read?
3. **Model layer:** Does `hermes model` show the right provider? Does `hermes doctor` pass?
4. **Tool layer:** Does `hermes tools list` show the needed toolsets enabled?
5. **Gateway layer:** Does `hermes gateway status` show the platform connected?

**Golden rule:** Prove `hermes chat -q` works before debugging Docker, gateways, or cron.

## The UID-Shift Disaster (v0.15.1 → v0.16.0)

**This is the one that strands you. No tools. No terminal. External help required.**

### What happened
Upstream Hermes v0.16.0 dropped `gosu` for `s6-setuidgid`, changing gateway runtime
user from **UID 1000 → UID 10000** (`HERMES_UID`). Every file under `/opt/data` that was
owned by UID 1000 became inaccessible to the new container running as UID 10000.

Result: SSH terminal dies with `Permission denied` on `/opt/data/hermes_ssh_key`.
ALL tools dead — terminal, read_file, write_file, patch, search_files. Nothing works.
**You have to SSH in from outside or use Claude externally.**
**External recovery guide:** `references/recovery.md` — written for an external AI
to guide a human operator through recovery step-by-step. Copy it to
`~/chubee/stack/RECOVERY.md` on ChubeeAcer so it's readable by the host user (UID 1000)
even when the container's UID 10000 locks you out of `~/.hermes/`.

### The fix (must be run from the Acer host via SSH)
```bash
docker exec -u 0 hermes chown -R 10000:1000 /opt/data
docker exec -u 0 hermes find /opt/data -type d -exec chmod 750 {} \;
docker exec -u 0 hermes find /opt/data -type f -exec chmod g+r {} \;
docker exec -u 0 hermes chmod 700 /opt/data/.ssh
docker exec -u 0 hermes chmod 600 /opt/data/hermes_ssh_key /opt/data/.ssh/known_hosts /opt/data/auth.json
```

### Why `chown -R 10000:10000` is WRONG
It satisfies the gateway but LOCKS THE HOST USER OUT. The host user `qcalmus` (UID 1000)
can no longer read `~/.hermes/` from SSH. **Group ownership (10000:1000)** with
group-read perms lets BOTH the gateway (UID 10000) AND host user (GID 1000) access.

### The `hermes` vs `hermes-dashboard` container trap

There are TWO containers from the same image. **Both can be running simultaneously
without obvious failure** — the second dashboard silently fails to bind port 9119
while the second gateway idles. This is dangerous because both gateways share
`state.db`, `gateway_state.json`, and cron jobs, risking data corruption.

**ALWAYS verify which container is live before stopping either:**
```bash
# Which PID binds port 9119 (the dashboard)?
sudo ss -tlnp | grep 9119
# Which container owns that PID?
docker inspect <container> --format '{{.State.Pid}}'
# Match the PID from ss output to the container's Pid.
```
KEEP the container that owns port 9119. Stop the other one. Do NOT assume
`hermes` is the live container — on ChubeeAcer, `hermes-dashboard` was the live one.

If `hermes` is down but `hermes-dashboard` is up, use `hermes-dashboard` for
`docker exec` commands. Both containers share the same `/opt/data` mount, so
file operations are equivalent regardless of which you exec into.

**Only ONE should run at a time.** If both show "Up" in `docker ps`:
1. Identify the live container (port 9119 holder)
2. Stop the OTHER one
3. Verify with `docker ps | grep hermes` — should show exactly one

### What "pinning the UID" means
The docker-compose.yml should specify `user: "10000:10000"` on the `hermes` service
so the runtime user is explicit, not inherited from the image. Without it, an image
rebuild can silently change the UID and replicate this disaster.

For NAS users (Unraid, Synology, UGOS): use `PUID`/`PGID` env vars as aliases for
`HERMES_UID`/`HERMES_GID`. The official docs recommend setting these to match the host
owner of the data mount:
```bash
docker run -d -e PUID=1000 -e PGID=10 -v /volume1/docker/hermes:/opt/data ...
```

### The `chmod 755` quick fix (try this first)
Before touching ownership, check if it's just a mode issue:
```bash
chmod -R 755 ~/.hermes
```
This is the official docs' first-line fix. If the data directory is bind-mounted
from a NAS and the container can't `chown`, set `PUID`/`PGID` instead.

### GH #10757: Agent resets $HERMES_DATA_DIR to chmod 700
Upstream bug: the agent repeatedly resets `/opt/data` permissions to mode 700,
removing group access. This cascades into "Permission denied" for tools that need
group-read. Check for this if permissions seem to degrade over time. Fix is
re-applying `chown -R 10000:1000 /opt/data` + `chmod 755` directories inside.

### Recovery when ALL tools are dead (SSH key permissions)
```bash
# From ChubeeAcer host:
sudo chmod 600 /home/qcalmus/.hermes/hermes_ssh_key
```
The container path `/opt/data/hermes_ssh_key` does NOT exist on the host —
the host sees `~/.hermes/hermes_ssh_key` which is owned by UID 10000, so `sudo` required.

## ChubeeAcer Reference

- **IP:** 100.65.206.99 (Tailscale)
- **SSH:** qcalmus@chubeeacer
- **Source:** ~/hermes-agent
- **Config:** ~/.hermes → /opt/data
- **Services:** gateway, dashboard (v0.16.0)
- **Local vLLM:** 172.17.0.1:8000 (Qwen, Nemotron)
- **Ollama:** 127.0.0.1:11434 (GLM vision)
- **Primary provider:** OpenRouter
- **Startup:** 3-4 minutes

## Filesystem Health Check

Run this periodically — it catches the silent failures that precede a full outage.
Full methodology: `references/audit-methodology.md`.

### 0. Verify before destroying
**Before recommending deletion of any container, file, or image:** prove your
assumptions with direct observation. The 2026-06-15 session nearly stopped the
wrong container because `docker ps` showed both running but didn't reveal which
one actually served traffic. Map PIDs to ports with `ss -tlnp`, cross-reference
with `docker inspect`, and always verify file contents between containers before
acting. The user will ask you to steelman your arguments — do it preemptively.

### 1. Containers: only ONE should be running
```bash
docker ps --format '{{.Names}} {{.Status}}' | grep hermes
```
If both `hermes` AND `hermes-dashboard` show "Up" → identify the live one first:
```bash
sudo ss -tlnp | grep 9119  # which PID serves the dashboard?
docker inspect hermes --format '{{.State.Pid}}'
docker inspect hermes-dashboard --format '{{.State.Pid}}'
```
Stop the container that does NOT own port 9119. Do NOT blindly stop
`hermes-dashboard` — on ChubeeAcer it was the live one.

### 2. state.db size
```bash
ls -lh /opt/data/state.db
```
Over 50MB → run `VACUUM`. Over 100MB → investigate session bloat.
```bash
sqlite3 /opt/data/state.db "VACUUM;"
```

### 3. No `.git/` in the data directory
```bash
ls -d /opt/data/.git/ 2>/dev/null && echo "REMOVE THIS" || echo "clean"
```
The data directory (`~/.hermes/`) should NOT be a git repo. It's already backed up
by other means. A `.git/` here adds 12MB+ of unnecessary objects and risks
accidentally committing secrets.

### 4. Stray log files in home root
```bash
ls -lh ~/download_*.log ~/chubee/*.txt 2>/dev/null
```
Move or delete. These are download artifacts that don't belong in the home root.

### 5. Relic recovery directories
```bash
ls -d ~/.hermes_fixed/ ~/.hermes-dashboard-logs/ ~/hermes-upgrade/ 2>/dev/null
```
Delete these. They're scratchpads from past recovery sessions that serve no
ongoing purpose.

### 6. Backup file sprawl
```bash
ls ~/.hermes/.env.bak-* ~/.hermes/config.yaml.bak-* ~/chubee/stack/docker-compose.yml.bak.* 2>/dev/null | wc -l
```
Keep 1-2 recent, delete the rest. They accumulate with every config change.

### 7. Stale Docker images
```bash
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E 'kokoro|litellm|open-webui|n8n|pgvector|adminer|signal|hello-world|cuda:12'
```
Images not in the active compose file are cruft. `docker rmi` them.