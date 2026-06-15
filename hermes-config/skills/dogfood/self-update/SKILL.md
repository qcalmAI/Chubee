---
name: self-update
description: "Update the Dockerized Hermes agent on Chubee (100.65.206.99) by pulling upstream into ~/hermes-agent/, rebuilding, and recreating containers. Covers the correct procedure, known pitfalls (restart vs recreate, --host default, startup delay), verification steps, and recovery. Use for any update that rebuilds the hermes-agent image."
version: 1.1.0
author: Chubee
license: MIT
metadata:
  hermes:
    tags: [hermes, upgrade, docker, compose, self-update]
    related_skills: [hermes-self-upgrade, docker-compose-services]
---

# Self-Update — Dockerized Hermes on Chubee

## When to Use

Any update that rebuilds the `hermes-agent:latest` image — pulling upstream,
merging fork branches, or rebuilding after config changes that require a new image.

**Not for full upstream fork merges** (major version jumps, merge-conflict resolution).
Those use `hermes-self-upgrade` which includes external-operator handoff for cutover.
This skill covers the routine update path: pull, build, recreate, verify.

## Correct Procedure

### Step 0 — Pre-check: Is there anything to update?

Before blindly pulling, verify there's actual work to do. A stale image on
current code needs only a rebuild; a stale fork behind upstream needs a full
self-upgrade.

```bash
cd ~/hermes-agent

# Check fork freshness
git fetch origin chubee-custom
git rev-list --left-right --count origin/chubee-custom...HEAD
# 0  0  → fork is current. Now check upstream:

git fetch upstream --tags
git rev-list --left-right --count upstream/main...HEAD
# 0  N  → we ARE upstream (unusual — we pushed ahead). Nothing to pull.
# N  0  → upstream has N new commits. NOT a routine self-update —
#         escalate to `hermes-self-upgrade` for full merge + cutover.
# N  M  → both sides diverged. Definitely self-upgrade territory.
```

**Decision rule:** If `upstream/main` is ahead by ANY amount, do NOT proceed
with this skill. Load `hermes-self-upgrade` instead. This skill is only for
rebuilding when the fork's code is already current.

### Step 1 — Pull fork (only if fork is behind itself)

```bash
git pull origin chubee-custom   # pulls fork-specific commits
```

### Step 2 — Build the new image

```bash
docker compose build gateway dashboard
```

### Step 3 — RECREATE containers — NEVER just restart

```bash
docker rm -f hermes hermes-dashboard
docker compose up -d gateway dashboard

# Wait — startup takes 3-4 minutes
# (ownership fixup on /opt/hermes runs on first start)
```

## Critical Pitfalls

### 1. `docker restart` does NOT re-read the compose file

**NEVER use `docker restart hermes` after a build.** `restart` stops and starts
the same container with its original config — it does not pick up the new image
or compose changes. Always `docker rm -f` then `docker compose up -d`.

### 2. Dashboard `--host` default breaks LAN access

The compose file may default to `--host 127.0.0.1`, which makes the dashboard
unreachable from any machine other than localhost. The correct command is:

```yaml
command: ["dashboard", "--host", "0.0.0.0", "--insecure", "--no-open"]
```

### 3. Container startup takes 3-4 minutes

After `docker compose up -d`, the gateway container runs ownership fixup on
`/opt/hermes` (chown + chmod across the bind-mounted `~/.hermes` directory).
This takes 3-4 minutes. **Do not assume failure until at least 4 minutes have passed.**

### 4. Starting stopped `hermes` container cascades UID-shift permission failures

After `docker start hermes` (the separate gateway container), it creates
directories under `/opt/data/` (e.g. `/opt/data/bin`, `/opt/data/memories`)
with UID-10000 ownership. This **breaks ALL tools in the running
`hermes-dashboard` container** — terminal returns PermissionError, memory
writes fail, tirith security checks crash. Both containers share the same
`/opt/data` bind-mount.

**Never `docker start hermes` while hermes-dashboard is running.**

If done by mistake, the recovery is:
```bash
docker stop hermes
sudo chown -R 10000:1000 /home/qcalmus/.hermes/
sudo chmod 600 /home/qcalmus/.hermes/hermes_ssh_key /home/qcalmus/.hermes/auth.json /home/qcalmus/.hermes/.env
docker restart hermes-dashboard
```

## Verification (mandatory after every update)

```bash
# 1. Confirm dashboard binds 0.0.0.0, not 127.0.0.1
ss -tlnp | grep 9119
# Expected: 0.0.0.0:9119 — NOT 127.0.0.1:9119

# 2. Confirm remote accessibility
curl -s -o /dev/null -w '%{http_code}' http://100.65.206.99:9119/
# Expected: 200

# 3. Confirm agent health
docker exec hermes hermes status
docker exec hermes hermes --version
```

**Do not consider the update complete until all three checks pass.**

## Recovery: Dashboard on 127.0.0.1

If `ss -tlnp | grep 9119` shows `127.0.0.1:9119` instead of `0.0.0.0:9119`:

```bash
# 1. Edit docker-compose.yml — ensure the dashboard command is:
#    command: ["dashboard", "--host", "0.0.0.0", "--insecure", "--no-open"]

# 2. Recreate ONLY the dashboard container
docker rm -f hermes-dashboard
docker compose up -d dashboard

# 3. Wait 30s, then verify
ss -tlnp | grep 9119    # must show 0.0.0.0
curl -s -o /dev/null -w '%{http_code}' http://100.65.206.99:9119/   # must show 200
```

## Environment

- **Host:** ChubeeAcer (NVIDIA GB10, ARM64)
- **IP:** 100.65.206.99
- **Compose:** `~/hermes-agent/docker-compose.yml`
- **Config/data:** `~/.hermes/` (bind-mounted to `/opt/data` inside container)
- **Containers:** `hermes` (gateway), `hermes-dashboard` (dashboard)

## Related Skills

- `hermes-self-upgrade` — full upstream fork merge with external-operator cutover
- `docker-compose-services` — general compose conventions, healthcheck patterns, UID-shift fix