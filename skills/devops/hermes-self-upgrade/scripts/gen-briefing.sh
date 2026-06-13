#!/usr/bin/env bash
# Generate a fresh, self-contained external-operator briefing for a Hermes self-upgrade.
# Probes the LIVE system so versions/branches/SHAs are never stale.
# Run this from the AGENT (it has terminal access) BEFORE the cutover, then have the
# user paste the output into a fresh claude.ai chat and TEST it with one question
# ("what's my rollback command and why does it work?") while the agent is still alive.
#
# Usage:  bash gen-briefing.sh [REPO_DIR] [OUT_FILE]
#   REPO_DIR defaults to ~/hermes-agent
#   OUT_FILE defaults to ~/hermes-upgrade/CLAUDE-BRIEFING.md
set -euo pipefail

REPO="${1:-$HOME/hermes-agent}"
OUT="${2:-$HOME/hermes-upgrade/CLAUDE-BRIEFING.md}"
mkdir -p "$(dirname "$OUT")"
cd "$REPO"

# --- probe live facts (best-effort; placeholders if a probe fails) ---
GW_CONTAINER="hermes"
DASH_CONTAINER="hermes-dashboard"
DASH_PORT="9119"

CUR_VER=$(grep -m1 '^version' pyproject.toml 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
LIVE_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
LIVE_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
git fetch upstream --tags -q 2>/dev/null || true
BEHIND_AHEAD=$(git rev-list --left-right --count upstream/main...HEAD 2>/dev/null || echo "? ?")
BEHIND=$(echo "$BEHIND_AHEAD" | awk '{print $1}')
AHEAD=$(echo "$BEHIND_AHEAD" | awk '{print $2}')
TARGET_VER=$(git show upstream/main:pyproject.toml 2>/dev/null | grep -m1 '^version' | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
SSH_HOST=$(docker exec "$GW_CONTAINER" sh -c 'echo $HERMES_SSH_HOST' 2>/dev/null || echo "see config")
HERMES_UID=$(docker exec "$GW_CONTAINER" sh -c 'id -u hermes 2>/dev/null' 2>/dev/null || echo "10000")
REMOTE_IP=$(grep -rhoE '100\.[0-9]+\.[0-9]+\.[0-9]+' "$HOME/.hermes" 2>/dev/null | head -1 || echo "<tailscale-ip>")
AHEAD_COMMITS=$(git log upstream/main..HEAD --oneline 2>/dev/null | head -10 || echo "(none)")

cat > "$OUT" <<EOF
# HERMES UPGRADE — TROUBLESHOOTING BRIEFING FOR CLAUDE
(generated $(date '+%Y-%m-%d %H:%M:%S') from live system state)

You are my remote operator for a high-stakes self-upgrade. Read all of this before
responding. At the end, confirm you understand and ask me for the first status output —
do not invent steps beyond this plan unless I hit a failure not covered here.

## WHO YOU ARE REPLACING
I run a local agent that lives INSIDE the Docker image we are about to rebuild. The
rebuild recreates the gateway container and kills that agent's session mid-flight. That
is why you exist: when the local agent goes dark, YOU guide me through verification,
troubleshooting, and — if needed — rollback. You cannot run commands. I am your hands.
You tell me exactly what to paste into an SSH shell; I paste output back; you interpret
and decide proceed vs. rollback.

## MY ACCESS
SSH as the host user to the Docker host. Web services also reachable remotely at
\`$REMOTE_IP\` (Tailscale). I am technically competent but want every destructive command
explained before I run it. Direct, no hedging.

## THE SYSTEM (probed live, do not second-guess)
- Source code: \`$REPO\` — git checkout, branch \`$LIVE_BRANCH\`, at \`$LIVE_SHA\`.
- Runtime config/data: \`~/.hermes\` mounted to \`/opt/data\` — **NOT git-tracked**, a
  SEPARATE dir (config, .env, SOUL.md, skills, memory, keys). A code upgrade physically
  cannot touch it. My customization is safe there.
- Current version: $CUR_VER. Target (upstream/main): $TARGET_VER.
  I am **$BEHIND behind / $AHEAD ahead** of upstream/main.
- My commits ahead of upstream (the ONLY real repo customization):
$(echo "$AHEAD_COMMITS" | sed 's/^/    /')
- Docker Compose v2 (\`docker compose\`). File \`$REPO/docker-compose.yml\`.
- Two containers from image \`hermes-agent:latest\`: service \`gateway\` -> container
  \`$GW_CONTAINER\` (cmd \`gateway run\`) — THIS IS THE AGENT; service \`dashboard\` ->
  container \`$DASH_CONTAINER\` (web UI port $DASH_PORT).
- Gateway runtime UID inside container: $HERMES_UID.

## HEALTH SIGNALS (agent alive = all three green)
- \`docker inspect $GW_CONTAINER --format '{{.State.Status}}'\` -> \`running\`
- \`docker exec $GW_CONTAINER hermes status\` -> exit 0 + status box
- \`curl -s -o /dev/null -w '%{http_code}\\n' http://localhost:$DASH_PORT/\` -> \`200\`
Confirm version moved: \`docker exec $GW_CONTAINER hermes --version\` (the status box omits version).

## PLAN
### Step 0 — Snapshot (touches nothing live)
\`\`\`
cd $REPO
git tag -f pre-upgrade-$LIVE_SHA
cp -a ~/.hermes ~/.hermes.bak-\$(date +%Y%m%d-%H%M%S)
docker tag hermes-agent:latest hermes-agent:rollback
git rev-parse HEAD   # RECORD THIS
\`\`\`
(The agent normally does Steps 0–3 itself before handing you the cutover. If the agent
already built and verified a new image, you start at Step 4.)
### Step 4 — CUTOVER (kills the local agent)
\`\`\`
cd $REPO && docker compose up -d --force-recreate gateway dashboard
\`\`\`
Wait 30–60s, then run all three health checks and the version check; paste outputs.
Open \`http://$REMOTE_IP:$DASH_PORT/\` to confirm remote access.
### Step 5 — Promote (only after all green)
\`\`\`
cd $REPO && git checkout $LIVE_BRANCH && git merge upgrade-test && git branch -d upgrade-test
\`\`\`

## ROLLBACK (your most important job)
If health fails after cutover and unfixable in minutes:
\`\`\`
cd $REPO && docker compose down
git checkout $LIVE_BRANCH
docker tag hermes-agent:rollback hermes-agent:latest
docker compose up -d --force-recreate gateway dashboard
\`\`\`
Then re-run health checks (brings the old working agent back). Restore data only if it
looks wrong: stop stack, \`mv ~/.hermes ~/.hermes.broken\`, \`cp -a\` newest
\`~/.hermes.bak-*\` back, recreate.

## LIKELY FAILURE MODES & FIXES
1. **#1 MOST LIKELY — UID-shift permission break.** If upstream changed privilege drop
   (gosu -> s6-setuidgid) the gateway may now run as a different UID ($HERMES_UID) than
   the files under /opt/data were created with. Symptom: SSH terminal backend dies with
   \`Load key "/opt/data/hermes_ssh_key": Permission denied\` and
   \`Failed to add the host to the list of known_hosts\`. FIX — use GROUP ownership so both
   the gateway (UID $HERMES_UID) and the host user can access. A blunt
   \`chown -R $HERMES_UID:$HERMES_UID\` fixes the gateway but LOCKS THE HOST USER OUT of
   ~/.hermes. Correct fix (from host shell; replace 1000 with host \`id -g\`):
   \`\`\`
   docker exec -u 0 $GW_CONTAINER chown -R $HERMES_UID:1000 /opt/data
   docker exec -u 0 $GW_CONTAINER find /opt/data -type d -exec chmod 750 {} \\;
   docker exec -u 0 $GW_CONTAINER find /opt/data -type f -exec chmod g+r {} \\;
   docker exec -u 0 $GW_CONTAINER chmod 700 /opt/data/.ssh
   docker exec -u 0 $GW_CONTAINER chmod 600 /opt/data/hermes_ssh_key /opt/data/auth.json
   \`\`\`
   NOTE: \`docker exec ... whoami\` shows root (exec defaults to root) — that is NOT the
   gateway's runtime user. Don't be alarmed.
2. **Gateway restart loop** — \`docker logs $GW_CONTAINER --tail 80\`; often a config
   schema change. Unfixable in minutes -> ROLLBACK.
3. **Dashboard not 200 but gateway running** — ensure dashboard service in
   docker-compose.yml matches upstream's networking (often \`network_mode: host\`).
4. **Build dep failure** (if you end up rebuilding) — \`docker compose build --no-cache gateway\`.
   Old container still runs; no rush.
5. **Merge conflict beyond docker-compose.yml** — config-only forks shouldn't have deep
   code conflicts; show me each file, decide together.

## WHEN TROUBLESHOOTING, ask for specific outputs
\`docker ps -a\`, \`docker logs $GW_CONTAINER --tail 100\`,
\`docker logs $DASH_CONTAINER --tail 50\`,
\`docker inspect $GW_CONTAINER --format '{{.State.Status}} restarts={{.RestartCount}}'\`,
\`git status\`, \`git log --oneline -5\`, \`df -h ~\`.

## SUCCESS
All three health signals green, dashboard reachable remotely, \`hermes status\` shows
model/keys intact, \`hermes --version\` reads the new version, and \`$LIVE_BRANCH\` is
fast-forwarded onto the tested merge. Then tell me we're done and the local agent should
be back.

---
END OF BRIEFING. Confirm your role, then ask me to run Step 0 (or the cutover, if the
agent already built+verified the new image) and paste the output.
EOF

echo "Briefing written to: $OUT"
echo "Current: $CUR_VER  ->  Target: $TARGET_VER   ($BEHIND behind, $AHEAD ahead)"
echo "Next: cat it, paste into a fresh claude.ai chat, and TEST it before cutover."
