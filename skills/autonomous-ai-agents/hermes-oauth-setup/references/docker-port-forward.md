# Docker OAuth Port Forwarding

The OAuth callback listener inside a Docker container binds to localhost.
This port is unreachable from outside the container. Two strategies:

## Strategy 1: SSH Tunnel (preferred for standard flows)

```bash
# On the user's local machine, forward the callback port
ssh -N -L <PORT>:127.0.0.1:<PORT> <linux-user>@<host>
```

- The `-N` flag keeps the tunnel open — it blocks the terminal until killed.
  Open a second terminal for subsequent steps.
- The SSH user on the remote machine must match the local user (Tailscale SSH
  maps connecting user → local user; mismatch causes `failed to look up local user`).
  Use explicit `ssh user@host`.
- The callback port must be reachable from inside the container. If the container
  uses bridge networking (not `--net=host`), verify port mapping in `docker-compose.yml`.

## Strategy 2: Manual-Paste (no SSH tunnel needed)

For services with restrictive redirect URI validation (e.g. Spotify validates
`127.0.0.1` only), use a file-based PKCE script:

1. Script generates PKCE params, prints auth URL, writes state/verifier to temp file
2. User opens URL in browser, approves, gets a failed redirect
3. User copies the failed redirect URL (which contains the authorization code in
   query params) into a trigger file
4. Script reads the code, exchanges it, writes tokens to `auth.json`

See `docker-oauth` skill for the Spotify-specific implementation.

## Port Forwarding Checklist

- [ ] Kill stale auth processes first: `docker exec <container> sh -c 'ps aux | grep "hermes auth" | grep -v grep | awk "{print \$2}" | xargs -r kill -9'`
- [ ] Check port is free: `docker exec <container> sh -c 'cat /proc/net/tcp | grep "$(printf "%04X" <port>)" || echo "free"'`
- [ ] Launch auth with `setsid` to survive the watcher: `docker exec <container> setsid bash -c 'hermes auth <service> ... > /tmp/<svc>-auth.log 2>&1'`
- [ ] Verify Tailscale SSH username match: connecting user == Linux user on host
- [ ] Test redirect URI from a clean browser session before involving the user

## Orphan Port Diagnosis

Stale `setsid`-detached auth processes leave socket entries in `/proc/net/tcp`
that don't show in `ss -tlnp` or `fuser`:

```bash
# Port 8888 in hex = 22B8
docker exec hermes sh -c 'cat /proc/net/tcp | grep 22B8'

# Find the PID owning a stale socket:
docker exec hermes sh -c '
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ -r "$p/fd" ] && ls -n "$p/fd" 2>/dev/null | grep -q "socket:[INODE]" && echo "PID=$pid"
done
'

# Kill all stale auth processes:
docker exec hermes sh -c 'ps aux | grep "hermes auth" | grep -v grep | awk "{print \$2}" | xargs -r kill -9'
```
