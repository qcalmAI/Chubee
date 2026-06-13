---
name: hermes-self-upgrade
description: "Upgrade the Dockerized Hermes gateway (the agent's own runtime) by merging upstream into a fork, rebuilding, and doing a survival-kit cutover that can't strand you. Use when pulling upstream Hermes changes into a self-hosted fork running in Docker, or any upgrade where rebuilding the image kills the agent guiding the upgrade."
version: 1.1.0
author: Quinton Calmus
license: MIT
metadata:
  hermes:
    tags: [hermes, upgrade, docker, fork, cutover]
    related_skills: [docker-compose-services, hermes-oauth-setup]
---

# Hermes Self-Upgrade (the agent upgrading its own runtime)

## When to use
- Self-hosted Hermes fork running in Docker; you want upstream fixes/features.
- The `hermes` gateway container IS the agent — the cutover
  (`docker compose up --force-recreate gateway`) kills the live session.
- Any upgrade where "if the new build is broken, the guide that would fix it is gone."

## The core problem & solution
Rebuilding the image recreates the gateway → the agent's session dies mid-flight.
If the new build is broken, the agent can't come back to fix it.

**Solution: do everything that leaves the agent alive (snapshot, merge, conflict
resolution, BUILD) inside the agent. Hand ONLY the final cutover + verification to an
external operator** (a fresh claude.ai chat fed a detailed briefing, or scripts on disk).

## Key architecture facts
- Source: `~/hermes-agent/` (git checkout). Runtime config/data: `~/.hermes/`
  (mounted to `/opt/data`, **NOT git-tracked**). A code upgrade physically cannot
  touch `~/.hermes/` — config, SOUL.md, skills, memory, keys are all safe.
- Two containers from image `hermes-agent:latest`: `gateway` → container `hermes`
  (the agent); `dashboard` → container `hermes-dashboard`.
- Compose v2 (`docker compose`, space).
- Fork delta is usually tiny. Measure before fearing a merge:
  ```bash
  git fetch upstream --tags
  git rev-list --left-right --count upstream/main...HEAD   # behind / ahead
  git log upstream/main..HEAD --oneline                    # YOUR real commits
  ```

## Health signals (agent alive = all three green)
```bash
docker inspect hermes --format '{{.State.Status}}'                 # -> running
docker exec hermes hermes status                                   # -> exit 0
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/    # -> 200
```
Confirm version: `docker exec hermes hermes --version` (NOT `hermes status` — it
omits version).

## Procedure

### Step 0 — Snapshot (touches nothing live)
```bash
cd ~/hermes-agent
git tag -f pre-upgrade-$(git rev-parse --short HEAD)     # rollback anchor
cp -a ~/.hermes ~/.hermes.bak-$(date +%Y%m%d-%H%M%S)     # config backup
docker tag hermes-agent:latest hermes-agent:rollback     # PRESERVE KNOWN-GOOD IMAGE
git rev-parse HEAD                                       # record SHA
```
**The single most important line is `docker tag ... hermes-agent:rollback`** — it
clones the current working brain. As long as that tag exists, rollback is one
`docker tag` away.

### Step 1 — Merge upstream on a throwaway branch
```bash
git fetch upstream --tags
git checkout -b upgrade-test
git merge upstream/main
```

### Step 2 — Resolve conflicts deliberately
- **A clean auto-merge of `docker-compose.yml` is a RISK.** If both your fork and
  upstream edited the same service, git may auto-combine non-overlapping hunks into
  a Frankenstein. ALWAYS diff: `git diff upstream/main:docker-compose.yml docker-compose.yml`
- Keep genuine preferences (e.g. dashboard `--host 0.0.0.0 --insecure`). Drop
  workarounds upstream has obsoleted.
- If files OTHER than expected conflict, STOP — config-only forks shouldn't have
  deep code conflicts.
```bash
git add -A && git commit -m "merge: <describe what you kept vs dropped>"
docker compose config -q       # validate compose syntax
```

### Step 3 — Build the new image (does NOT go live)
```bash
docker compose build gateway
```
Builds take 5+ min. Foreground tool times out at 180s — that is NOT a failure.
Re-run in background:
```bash
nohup docker compose build gateway > ~/hermes-upgrade/build.log 2>&1 &
```
**Verify the image actually repointed:**
```bash
docker images hermes-agent:latest --format '{{.ID}} {{.CreatedSince}}'
docker run --rm --entrypoint hermes hermes-agent:latest --version
```

### Step 4 — Cutover (HAND TO EXTERNAL OPERATOR — kills the agent)
```bash
cd ~/hermes-agent && docker compose up -d --force-recreate gateway dashboard
```
Wait 30-60s, run the three health checks, confirm version. The agent's session
ends here; the external operator drives until green.

### Step 5 — Promote (only after all green)
```bash
git checkout chubee-custom && git merge upgrade-test && git branch -d upgrade-test
```

### Rollback (operator's job)
```bash
cd ~/hermes-agent && docker compose down
git checkout <live-branch>
docker tag hermes-agent:rollback hermes-agent:latest
docker compose up -d --force-recreate gateway dashboard
```

## Running Hermes CLI from within Docker

Many admin tasks require `hermes` CLI. When Hermes runs in Docker, use the container:

```bash
docker exec hermes hermes tools list         # non-interactive
docker exec hermes hermes auth status spotify
docker exec hermes hermes config set ...
docker exec hermes hermes --version
```

**Interactive wizards need PTY but can't accept input through the terminal tool.**
Pre-supply values via flags or env vars:

```bash
# WORKS — non-interactive (flags provided):
docker exec hermes hermes auth spotify --client-id <id>

# WORKS — non-interactive (env var set):
export HERMES_SPOTIFY_CLIENT_ID=<id>
docker exec hermes hermes auth spotify

# DOES NOT WORK — wizard asks interactively:
docker exec hermes hermes auth spotify     # stalls, no way to type
```

For OAuth flows from Docker, see `hermes-oauth-setup` skill and
`references/docker-port-forward.md` there.

## External operator briefing — AUTO-GENERATED every upgrade

Do NOT hand-write the briefing. Use the bundled generator:
```bash
bash scripts/gen-briefing.sh                 # writes ~/hermes-upgrade/CLAUDE-BRIEFING.md
```
**TEST the lifeline before cutover:** paste the briefing into claude.ai and ask
"what's my rollback command and why does it work?" If coherent, the operator is
proven. If confused, regenerate before proceeding.

Host-vs-container path gotcha: if `~/.hermes` is owned by gateway UID (10000), pipe
through the container:
```bash
docker exec hermes cat /opt/data/skills/devops/hermes-self-upgrade/scripts/gen-briefing.sh > /tmp/gen-briefing.sh
bash /tmp/gen-briefing.sh
```

## Post-upgrade cleanup — MANUAL, never automatic

The rollback image + data backup are your safety net. Do NOT auto-delete. Wait a
couple stable days, push the branch, THEN delete by hand:
```bash
git push origin <live-branch>
docker rmi hermes-agent:rollback
rm -rf ~/.hermes.bak-*
git tag -d pre-upgrade-*
```

## Pitfalls

Key pitfalls from real upgrades (full incident log: `references/incident-log.md`):

1. **UID shift breaks /opt/data permissions** — see `docker-compose-services` skill
   for the group-ownership fix.
2. **Clean compose auto-merge can be wrong** — always diff merged compose against
   pure upstream (Step 2).
3. **Foreground build timeout (180s) is not a failure** — background it; verify
   final image id + version.
4. **`hermes status` omits version number** — use `hermes --version`.
5. **calver vs semver jump** — pyproject.toml is authoritative; tags may disagree.
6. **Set git identity before committing** (`git config user.email/name`).
7. **`git commit --no-edit` on empty stage aborts** — stage edits, give a real `-m`.
8. **The `hermes` container can be stopped while `hermes-dashboard` is live.** Post-upgrade, always check both containers with `docker ps --format '{{.Names}} {{.Status}}' | grep hermes`. If `hermes` is "Created" or "Exited" but `hermes-dashboard` is "Up", use `hermes-dashboard` for all `docker exec` commands. Both share the same `/opt/data` mount.
