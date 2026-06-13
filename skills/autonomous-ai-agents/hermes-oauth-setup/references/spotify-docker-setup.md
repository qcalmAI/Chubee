# Spotify OAuth — Docker/SSH Setup Notes

Session-specific detail from the initial Spotify integration on ChubeeAcer (Dockerized Hermes, Tailscale SSH).

## Spotify App Settings (Developer Dashboard)

Create app at https://developer.spotify.com/dashboard with:

| Field | Value |
|-------|-------|
| App name | `hermes-agent` (or anything) |
| App description | anything |
| Redirect URI | `http://127.0.0.1:<port>/spotify/callback` |
| API/SDK | Web API |

App lives in **Development mode** by default. This is fine for personal use.

Settings page allows multiple redirect URIs — keep a few spare ports registered so you can swap if one is stuck:
```
http://127.0.0.1:43828/spotify/callback
http://127.0.0.1:43829/spotify/callback
```

## Port Selection

The default is 43827, but any free port works. Pick one that's not in `/proc/net/tcp`. Spotify's HTTPS redirect back to the local listener must match exactly.

## PKCE, Not Secrets

Spotify PKCE OAuth does NOT use the client secret — only the Client ID. Never pass the client secret to Hermes.

## Port Cleanup

Stale auth processes survive the Hermes watcher because `setsid` fully detaches. Check with:

```bash
docker exec hermes sh -c 'ps aux | grep "hermes auth spotify" | grep -v grep'
```

Kill by PID or use:
```bash
docker exec hermes sh -c 'fuser -k <port>/tcp 2>/dev/null; sleep 1'
```

## Redirect URI Mismatch Diagnosis

If the user gets "redirect_uri: Not matching configuration":
1. Verify the EXACT string in the Spotify dashboard matches the auth URL
2. Check for trailing slashes, port differences, protocol (http vs https)
3. Have the user confirm they clicked "Save" after adding the URI
4. Try a completely fresh port the user adds to the dashboard
5. **Test from a clean browser session** — use the browser tool or curl to navigate to the auth URL. If it shows the Spotify login page (not an error), the redirect URI is valid and the issue is on the user's end (browser cache, wrong URL, logged into wrong account)
6. Spotify's server validates for 127.0.0.1 only — localhost and Tailscale IPs are rejected server-side

## SSH Tunnel Command

```bash
ssh -N -L <port>:127.0.0.1:<port> <linux-user>@<host>
```

For Tailscale: use the Tailscale hostname or IP (e.g., `100.x.x.x`). The user's Windows username almost never matches the Linux username; always use `linuxuser@host`.

## Free Account Limitations

- Search, library, playlists, albums: work on Free
- Playback control (play, pause, skip, volume, transfer): requires Premium
- Queue add: requires Premium
