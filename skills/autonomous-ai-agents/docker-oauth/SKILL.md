---
name: docker-oauth
description: "Complete Spotify OAuth when Hermes runs inside Docker — the manual-paste PKCE script, SSH tunnel option, port conflict diagnosis, and browser-side redirect verification. Use when linking Spotify to a Dockerized Hermes. For general OAuth flow (any service), see hermes-oauth-setup."
version: 1.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [oauth, spotify, docker, ssh-tunnel]
    related_skills: [hermes-oauth-setup, hermes-self-upgrade]
---

# Docker OAuth — Spotify

Spotify OAuth from inside a Dockerized Hermes. For the general OAuth workflow
(any service: Google, GitHub Copilot, etc.), see `hermes-oauth-setup`. This
skill covers ONLY Spotify-specific deltas.

## Why this is hard

1. The auth wizard needs TTY — `docker exec` without `-it` fails.
2. The callback server binds to container loopback (127.0.0.1), unreachable
   from the user's browser.
3. Spotify's OAuth server validates redirect URIs for `127.0.0.1` ONLY —
   Tailscale IPs and `localhost` are rejected server-side.

## Quick Reference

| Problem | Fix |
|---|---|
| Auth wizard needs TTY | Use PTY mode or skip wizard entirely |
| Callback unreachable | SSH tunnel, or manual-paste file-based approach |
| Redirect URI rejected by Spotify | Must use `http://127.0.0.1:<port>` |

## Solution C: Manual-Paste PKCE Script (most reliable, no SSH tunnel)

Use the bundled `scripts/spotify_manual_paste.py`. It generates PKCE params,
prints the auth URL, writes state/verifier to a temp file, then waits for a
callback URL file. User pastes the failed redirect URL into that file; the
script exchanges the code and writes tokens to `auth.json`.

```bash
# 1. Copy script into container
docker cp scripts/spotify_manual_paste.py hermes:/tmp/

# 2. Edit CLIENT_ID at the top of the script

# 3. Run as background (file-based wait, non-interactive)
docker exec hermes python3 /tmp/spotify_manual_paste.py &

# 4. Read the auth URL
docker exec hermes cat /tmp/spotify_auth_url.txt

# 5. User opens URL in browser, approves, gets a failed redirect

# 6. Write the callback URL into the trigger file
docker exec hermes sh -c 'cat > /tmp/spotify_callback.txt'

# 7. Script picks it up, exchanges, writes to auth.json

# 8. Verify
docker exec hermes hermes auth status spotify
```

## Solution A: SSH Tunnel (works for localhost-only redirect URIs)

See the shared port-forward reference in `hermes-oauth-setup`:
`skill_view(name='hermes-oauth-setup', file_path='references/docker-port-forward.md')`

Quick summary:
```bash
# On local machine:
ssh -N -L <PORT>:127.0.0.1:<PORT> <user>@<host>

# In Docker:
docker exec hermes hermes auth spotify --client-id <id> --redirect-uri http://127.0.0.1:<PORT>/spotify/callback --timeout 600
```

**Pitfall — Tailscale SSH username mismatch:** The connecting user's local
username (e.g. Windows `qcalm`) must match the Linux user (`qcalmus`).
Use explicit `user@host` syntax.

## Where Tokens Are Stored

`/opt/data/auth.json` → `providers.spotify`. The manual script writes directly
to this path.

## Verifying

```bash
docker exec hermes hermes auth status spotify
# Expected: "spotify: logged in"
```

## Verifying Redirect URI Acceptance

Test from a clean browser session:
1. Navigate to the auth URL directly
2. If Spotify login page shows (not an error), the redirect URI is valid
3. If `redirect_uri: Not matching configuration`, the URI in Spotify app
   settings doesn't match

## Diagnosing Orphan Ports

Stale `setsid`-detached auth processes leave socket entries in `/proc/net/tcp`
that don't show in `ss -tlnp` or `fuser`:

```bash
# Port 8888 in hex = 22B8
docker exec hermes sh -c 'cat /proc/net/tcp | grep 22B8'

# Kill all stale auth processes:
docker exec hermes sh -c 'ps aux | grep "hermes auth" | grep -v grep | awk "{print \$2}" | xargs -r kill -9'
```
