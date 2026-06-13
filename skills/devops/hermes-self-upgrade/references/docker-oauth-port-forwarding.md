# OAuth Port Forwarding for Dockerized Hermes

OAuth flows (Spotify, Google, GitHub, etc.) use a local PKCE callback server
that binds to a localhost port inside the container. That port is **not exposed**
by default. You need SSH local forwarding to complete the flow.

## Spotify example (the most common case)

### Prerequisites
- Spotify Developer app (2 min setup at https://developer.spotify.com/dashboard)
- Spotlightify toolset enabled (`docker exec hermes hermes tools` → toggle 🎵, save)
- For playback: Premium account + an active Spotify Connect device

### Auth flow

1. **Kill any stale listeners** on the port (default 43827):
   ```bash
   docker exec hermes sh -c 'fuser -k 43827/tcp 2>/dev/null; sleep 1'
   ```

2. **Run the auth wizard** with pre-supplied Client ID and optional custom redirect URI:
   ```bash
   docker exec hermes hermes auth spotify --client-id <ID>
   ```
   It prints an authorization URL and starts listening on 127.0.0.1:43827.

3. **On your local machine, forward the port** so Spotify's redirect reaches the container:
   ```bash
   ssh -N -L 43827:127.0.0.1:43827 chubeeacer
   ```

4. **Open the printed URL** in your browser, approve the consent screen.
   Spotify redirects to 127.0.0.1:43827 on YOUR machine → SSH tunnel → container listener.

### Port 43827 stuck? ("Address already in use")

The prior listener's socket may be in TIME_WAIT. `fuser` often can't clear it
inside Docker. Two workarounds:

- **Wait 1-3s** and retry (TIME_WAIT clears eventually).
- **Use a different port** via `--redirect-uri`:
  ```bash
  docker exec hermes hermes auth spotify --client-id <ID> --redirect-uri http://127.0.0.1:43828/spotify/callback
  ```
  Then forward **that** port instead:
  ```bash
  ssh -N -L 43828:127.0.0.1:43828 chubeeacer
  ```
  **Must also add the new redirect URI** to your Spotify app's settings
  (developer dashboard → app → Settings → Edit Settings → Redirect URIs).

### Running non-interactively

The `--client-id` flag skips the interactive prompt. For headless/dockerized
use, always pre-supply it — the terminal tool's `pty=true` can show wizard
output but cannot accept keyboard input.

```bash
# GOOd
docker exec hermes hermes auth spotify --client-id a840cf2b2df64145a4632dfc26833ba4

# Also good (env var)
export HERMES_SPOTIFY_CLIENT_ID=<id>
docker exec hermes hermes auth spotify

# BAD — interactive prompt, no way to type response:
docker exec hermes hermes auth spotify   # (stalls on "Client ID:" prompt)
```

### Verify auth

```bash
docker exec hermes hermes auth status spotify
# → spotify: logged in (expires ...)
```

Tokens stored in `~/.hermes/auth.json` under `providers.spotify`. Auto-refresh
on 401; you only re-auth if you revoke the app or run `hermes auth logout spotify`.

### Scope note

Default scopes cover all shipped tools. To restrict:
```bash
docker exec hermes hermes auth spotify --client-id <ID> --scope "user-read-playback-state playlist-read-private"
```

## General pattern for any OAuth provider

```bash
docker exec hermes hermes auth <provider> [--client-id <ID>] [--redirect-uri <URI>]
# → prints auth URL, starts listener
# From local machine:
ssh -N -L <PORT>:127.0.0.1:<PORT> <remote-host>
# Open auth URL in browser, approve
```

## Common pitfalls

| Pitfall | Fix |
|---------|-----|
| `Could not bind ... [Errno 98] Address already in use` | Use a different port via `--redirect-uri` |
| `INVALID_CLIENT: Invalid redirect URI` | Add the exact redirect URI to the app's allowed list |
| Browser says "Can't reach localhost" after auth | SSH tunnel not running or wrong port |
| `401 Unauthorized` keeps coming back | Refresh token revoked; re-auth with `hermes auth <provider>` |
| `403 Premium required` | Free account; playback mutations need Premium |
| `403 No active device found` | Open Spotify on any device first (play a track to register it) |