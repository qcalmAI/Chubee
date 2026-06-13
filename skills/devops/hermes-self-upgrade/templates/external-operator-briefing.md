# EXTERNAL-OPERATOR BRIEFING TEMPLATE (static fallback)
#
# PREFER scripts/gen-briefing.sh — it probes the live system and fills everything in.
# Use THIS manual template only if the generator can't run. Fill the <PLACEHOLDERS> with
# values VERIFIED from the live system (probe, don't guess), then give the whole block to
# the user to paste into a fresh claude.ai conversation. Everything below the line is what
# the user pastes.
# ---------------------------------------------------------------------------------------

You are acting as my backup operator for a high-stakes self-upgrade. Read all of this
before responding. At the end, confirm you understand and ask me for the first status
output — do not invent steps beyond this plan unless I hit a failure not covered here.

## WHO YOU ARE REPLACING
I run a local agent that lives INSIDE the Docker image we are about to rebuild. The
rebuild recreates the gateway container, killing that agent's session mid-flight. That is
why you exist here: when the local agent goes dark, YOU guide me through verification,
troubleshooting, and — if needed — rollback. You cannot run commands. I am your hands.

## MY ACCESS
- SSH as user `<SSH_USER>` to host `<HOST>`.
- Web services also reachable at `<REMOTE_IP / Tailscale>`.
- I'm technically competent but want every destructive command explained first. Direct,
  no hedging.

## THE SYSTEM (verified facts)
- Source code: `<REPO_PATH>` — git checkout, branch `<LIVE_BRANCH>`.
- Runtime config/data: `<DATA_DIR>` — NOT git-tracked, SEPARATE dir; a code upgrade
  cannot touch it.
- Current version `<OLDVER>`; upgrading to `<NEWVER>`. <N> commits behind upstream.
- Remotes: origin=<ORIGIN>, upstream=<UPSTREAM>.
- Docker Compose v2. Two containers from image `hermes-agent:latest`:
  - service `gateway` -> container `hermes` (cmd `gateway run`) — THIS IS THE AGENT.
  - service `dashboard` -> container `hermes-dashboard` (web UI port 9119).

## MY REAL REPO CUSTOMIZATION
<DESCRIBE the one/few diverging commits and which lines to KEEP vs DROP on conflict>

## HEALTH SIGNALS (agent alive = all three green)
- `docker inspect hermes --format '{{.State.Status}}'` -> running
- `docker exec hermes hermes status` -> exit 0 + status box (CLI is inside the container)
- `curl -s -o /dev/null -w '%{http_code}' http://localhost:9119/` -> 200

## STATE WHEN HANDED TO YOU
- New image `:latest` already BUILT and verified to boot at `<NEWVER>`.
- Old image preserved as `hermes-agent:rollback`.
- Merge resolved + committed on branch `<WORK_BRANCH>`. Data backed up at `<BACKUP_PATH>`.

## STEP 4 — CUTOVER (kills the local agent)
`cd <REPO_PATH> && docker compose up -d --force-recreate gateway dashboard`
Wait 30-60s, run all three health checks, paste outputs. Then verify dashboard over
`<REMOTE_IP>:9119`, and `docker exec hermes hermes status` shows model/keys intact.

## STEP 5 — PROMOTE (only if all green)
`cd <REPO_PATH> && git checkout <LIVE_BRANCH> && git merge <WORK_BRANCH> && git branch -d <WORK_BRANCH>`

## ROLLBACK (your most important job)
`cd <REPO_PATH> && docker compose down && git checkout <LIVE_BRANCH> && docker tag hermes-agent:rollback hermes-agent:latest && docker compose up -d --force-recreate gateway dashboard`
Then re-run health checks (brings the old working agent back). If `<DATA_DIR>` looks wrong:
stop stack, `mv <DATA_DIR> <DATA_DIR>.broken`, `cp -a` the newest backup back, recreate.

## LIKELY FAILURES & FIXES
1. Build dep failure -> paste error; old container still runs; try `--no-cache`.
2. Gateway restart loop -> `docker logs hermes --tail 80`; likely config-schema/startup
   change; unfixable in minutes -> ROLLBACK.
3. Dashboard not 200 but gateway running -> ensure dashboard service matches upstream
   (host networking / shared PID namespace) plus only the intended command tweak.
4. /opt/data PERMISSION errors (gosu -> s6-setuidgid UID shift) — the #1 observed
   regression. Symptom: SSH backend dies with `Load key ".../hermes_ssh_key": Permission
   denied`. The gateway now runs as a NEW uid (e.g. 10000) but /opt/data files were created
   as the old uid (1000). FIX — group ownership so BOTH gateway and host user can access
   (a blunt `chown -R 10000:10000` fixes the gateway but LOCKS THE HOST USER OUT):
   `docker exec -u 0 hermes chown -R 10000:1000 /opt/data`
   `docker exec -u 0 hermes find /opt/data -type d -exec chmod 750 {} \;`
   `docker exec -u 0 hermes find /opt/data -type f -exec chmod g+r {} \;`
   `docker exec -u 0 hermes chmod 700 /opt/data/.ssh && chmod 600 /opt/data/hermes_ssh_key /opt/data/auth.json`
   (replace 1000 with host `id -g`).
5. Non-compose merge conflicts -> don't blind-accept; show me each.
6. `docker compose` missing -> try `docker-compose` (hyphen).

## WHEN TROUBLESHOOTING, ask me for specific command output:
`docker ps -a`, `docker logs hermes --tail 100`, `docker logs hermes-dashboard --tail 50`,
`docker inspect hermes --format '{{.State.Status}} restarts={{.RestartCount}}'`,
`git status`, `git log --oneline -5`, `df -h ~`.

## SUCCESS = all three health signals green, dashboard reachable remotely, `hermes status`
shows model/keys intact, version reads `<NEWVER>`, and `<LIVE_BRANCH>` fast-forwarded onto
the tested merge.

END OF BRIEFING. Confirm your role, then ask me to run Step 0 / the cutover and paste outputs.
