---
name: hermes-oauth-setup
description: "Configure OAuth-based service integrations (Spotify, Google, GitHub Copilot, etc.) with Hermes Agent, with specific patterns for Docker containers accessed over SSH/Tailscale. Use when linking any external service to a Dockerized Hermes, or troubleshooting OAuth callback failures. For Spotify-specific deltas, see docker-oauth."
version: 1.1.0
author: agent
metadata:
  hermes:
    tags: [oauth, docker, ssh-tunnel, spotify, google]
    related_skills: [docker-oauth, hermes-self-upgrade]
---

# Hermes OAuth Setup (Docker)

Configure OAuth integrations when Hermes runs inside a Docker container accessible
over SSH/Tailscale. The OAuth callback listener binds to a localhost port inside
the container, unreachable from the user's browser — this skill solves that.

## When to Use

User asks to link/connect/authorize any external service (Spotify, Google, GitHub, etc.).
Check `hermes tools list` first — the toolset must be enabled before auth works.

## Prerequisites

- The service's toolset must be enabled (`hermes tools` → toggle → `/reset`)
- User needs a developer account on the service
- `docker exec` access to the container

## The Docker OAuth Problem

| Problem | Cause | Fix |
|---|---|---|
| Auth wizard needs TTY | `docker exec` without `-it` | Use PTY mode, or skip wizard |
| Callback unreachable | Listener on container loopback | SSH tunnel, or manual-paste script |
| Redirect URI validation | Hermes validates `127.0.0.1`/`localhost` only | Use manual-paste (no patching needed) |
| Watcher kills auth process | `terminal(background=true)` SIGTERM after ~300s | Use `setsid` to fully detach |

## General Docker Workflow

### Step 1: Kill stale processes

Old auth listeners hold ports even after the watcher kills the parent:

```bash
docker exec hermes sh -c 'fuser -k <port>/tcp 2>/dev/null; sleep 1'
```

Verify port free:
```bash
docker exec hermes sh -c 'cat /proc/net/tcp | grep "$(printf "%04X" <port>)" || echo "port free"'
```

### Step 2: Launch auth fully detached

Use `setsid` + logfile to outlive the Hermes watcher:

```bash
docker exec hermes setsid bash -c \
  'hermes auth <service> --client-id <id> --redirect-uri http://127.0.0.1:<port>/<service>/callback --timeout 600 \
   > /tmp/<service>-auth.log 2>&1'
```

- `--timeout 600` gives the user 10 minutes
- `setsid` detaches from the process tree — watcher can't touch it

### Step 3: Get the auth URL

```bash
docker exec hermes head -15 /tmp/<service>-auth.log
```

### Step 4: SSH tunnel (if using tunnel approach)

For the full SSH tunnel pattern (port forwarding, Tailscale username gotcha,
diagnosing orphan ports), see `references/docker-port-forward.md`.

Quick reference — on the user's local machine:
```bash
ssh -N -L <port>:127.0.0.1:<port> <linux-user>@<host>
```

**⚠️ Tailscale SSH:** The local username (e.g. Windows `qcalm`) must match the
Linux username (`qcalmus`). Always use explicit `user@host` syntax.

### Step 5: User approves in browser

They open the auth URL, approve OAuth consent, service redirects through the
SSH tunnel → Docker container → Hermes listener.

### Step 6: Verify

```bash
docker exec hermes hermes auth status <service>
```

## Common Pitfalls

- **Port already in use:** Kill stale processes (Step 1 above).
- **`redirect_uri: Not matching configuration`:** URI in service dashboard must
  EXACTLY match the auth URL (no trailing slash, correct port).
- **SSH tunnel fails with "failed to look up local user":** Use explicit
  `<linux-user>@<host>` syntax.
- **No tmux inside Docker container:** Use `setsid` instead.
- **Browser opens stale auth URL:** After killing/restarting auth flow, the old
  URL's `state` and `code_challenge` are invalid. Always give the user the NEW URL
  from the fresh log file.

## Per-Service Notes

| Service | Reference | Key Quirk |
|---|---|---|
| Spotify | `docker-oauth` skill | App must be in dev mode; PKCE flow; Spotify validates 127.0.0.1 only |

## Verification

```bash
docker exec hermes hermes auth status <service>
# Should show: <service>: logged in
```
