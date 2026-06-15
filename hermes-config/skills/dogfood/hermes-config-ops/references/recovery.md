# ChubeeAcer Hermes Recovery Guide

**For the AI reading this:** You are guiding a human through recovery of a self-hosted
Hermes Agent instance running in Docker on an ARM64 machine (ChubeeAcer). The human is
SSH'd in as `qcalmus`. The container may be dead, partially broken, or working but
missing tools. Your job is to diagnose which of the three scenarios below applies and
walk them through the fix. Start with the health checks, then follow the matching
scenario. Do NOT skip verification steps.

---

## System Facts (for the AI)

- **Host:** ARM64 (Acer GB10), Tailscale IP 100.65.206.99
- **User:** qcalmus (UID 1000), home at /home/qcalmus
- **Docker:** Compose v2, file at ~/hermes-agent/docker-compose.yml
- **Container image:** hermes-agent:latest (v0.16.0)
- **Container runtime user:** UID 10000
- **Data mount:** /home/qcalmus/.hermes → /opt/data (inside container)
- **Two containers:** `hermes` (gateway) and `hermes-dashboard` (dashboard+gateway).
  Only ONE should run at a time — having both up causes permission conflicts on the
  shared /opt/data mount.
- **Startup time:** 3-4 minutes after container start
- **Dashboard:** http://100.65.206.99:9119
- **Full docs:** /home/qcalmus/.hermes/skills/dogfood/hermes-config-ops/SKILL.md

---

## Step 0: Health Check (always run first)

Ask the human to run these and share the output:

```bash
# Are the containers running?
docker ps --format '{{.Names}} {{.Status}}' | grep hermes

# Is the dashboard responding?
curl -s http://100.65.206.99:9119/api/status

# Can we exec into a container?
docker exec hermes whoami 2>&1 || docker exec hermes-dashboard whoami 2>&1
```

**What to look for:**
- If NO containers are running → Scenario 1 (container startup)
- If containers run but `docker exec` shows "Permission denied" → Scenario 2 (SSH key)
- If containers run, exec works, but human says tools are missing → Scenario 3 (config)
- If containers are "Created" or "Exited" → Scenario 1

---

## Scenario 1: Container Won't Start or Shows "Exited"

The container likely hit a UID mismatch and refused to start, or started but crashed.
A simple `docker restart` won't fix this — you need `--force-recreate`.

### Fix

```bash
cd ~/hermes-agent
docker compose up -d --force-recreate
```

### Verify

Wait 3-4 minutes, then:

```bash
docker ps --format '{{.Names}} {{.Status}}' | grep hermes
# Should show ONE container "Up"
curl -s http://100.65.206.99:9119/api/status
# Should show "gateway_running": true
```

### If still failing

Check the logs:

```bash
docker logs hermes --tail 30 2>/dev/null || docker logs hermes-dashboard --tail 30
```

Look for "Permission denied" on /opt/data — if present, go to Scenario 4.

---

## Scenario 2: Containers Run But Terminal Tools Fail Silently

The human says "terminal commands don't work" or "can't read files" but the agent
can still chat. This is usually a wrong file mode on the SSH key.

### Check

```bash
docker exec hermes ls -la /opt/data/hermes_ssh_key
```

If the mode shows `-rw-r-----` (0640) or `-rwxr-xr-x` (0755), it needs to be 0600.

### Fix

```bash
sudo chmod 600 /home/qcalmus/.hermes/hermes_ssh_key
docker restart hermes 2>/dev/null || docker restart hermes-dashboard 2>/dev/null
```

**Why sudo:** The file is owned by UID 10000 (the container user), not qcalmus (UID 1000).
The host path is /home/qcalmus/.hermes/hermes_ssh_key — NOT /opt/data/hermes_ssh_key
(that path only exists inside the container).

---

## Scenario 3: Tools Missing After Config Change

The human changed a config setting but the agent doesn't see the change. This is
normal — Hermes reads config at session start and caches it. A fresh session is needed.

### Fix

Tell the human: "Start a new chat session in Hermes — type `/new` in the TUI or
open a fresh tab. Do NOT resume an existing session. The config change only takes
effect in brand-new sessions."

If the problem is that `hermes` CLI itself is on the wrong PATH:

```bash
docker exec hermes which hermes
# Should show /opt/hermes/.venv/bin/hermes
```

---

## Scenario 4: Full UID Disaster — Permission Denied Everywhere

The container runs but EVERY tool fails with "Permission denied." The gateway can't
read its own files because they're owned by the wrong UID.

**This happens after:** A Hermes version upgrade, a container rebuild, or accidentally
running `chown` on the data directory.

### The Rule

The container runs as UID 10000. Every file under /home/qcalmus/.hermes must be
**owned by 10000:1000** (container user owns, host group can read).

**Never use `chown -R 10000:10000`** — that locks the host user qcalmus out of the
directory entirely. Group ownership (10000:1000) lets both sides work.

### Fix

Run each command one at a time, in order:

```bash
# Step 1: Fix ownership (container user owns, host group can read)
docker exec -u 0 hermes chown -R 10000:1000 /opt/data

# Step 2: Directories readable+executable by group
docker exec -u 0 hermes find /opt/data -type d -exec chmod 750 {} \;

# Step 3: Files readable by group
docker exec -u 0 hermes find /opt/data -type f -exec chmod g+r {} \;

# Step 4: Re-tighten secrets (the broad chmod made them group-readable)
docker exec -u 0 hermes chmod 700 /opt/data/.ssh
docker exec -u 0 hermes chmod 600 /opt/data/hermes_ssh_key
docker exec -u 0 hermes chmod 600 /opt/data/.ssh/known_hosts
docker exec -u 0 hermes chmod 600 /opt/data/auth.json
```

### If `docker exec -u 0 hermes` fails (container is completely dead)

The data directory lives on the host at /home/qcalmus/.hermes. Use sudo:

```bash
sudo chown -R 10000:1000 /home/qcalmus/.hermes
sudo find /home/qcalmus/.hermes -type d -exec chmod 750 {} \;
sudo find /home/qcalmus/.hermes -type f -exec chmod g+r {} \;
sudo chmod 700 /home/qcalmus/.hermes/.ssh
sudo chmod 600 /home/qcalmus/.hermes/hermes_ssh_key
sudo chmod 600 /home/qcalmus/.hermes/.ssh/known_hosts
sudo chmod 600 /home/qcalmus/.hermes/auth.json
```

### Verify

```bash
docker restart hermes 2>/dev/null || docker restart hermes-dashboard 2>/dev/null
# Wait 30 seconds
docker exec hermes ls -la /opt/data/hermes_ssh_key
# Should show -rw------- (0600) owned by 10000:1000
```

---

## Scenario 5: Both Containers Running Simultaneously

This creates a permission war — one container creates files the other can't read.
Only ONE of `hermes` or `hermes-dashboard` should run at a time.

### Fix

```bash
# Stop both
docker stop hermes hermes-dashboard 2>/dev/null

# Pick one (dashboard is simpler — it bundles both dashboard UI + gateway)
cd ~/hermes-agent && docker compose up -d --force-recreate hermes-dashboard
```

---

## Reference

- **Full skill docs:** /home/qcalmus/.hermes/skills/dogfood/hermes-config-ops/SKILL.md
- **Docker compose:** ~/hermes-agent/docker-compose.yml
- **Acer SSH:** qcalmus@chubeeacer (Tailscale)
- **Dashboard:** http://100.65.206.99:9119
- **Hermes version:** v0.16.0