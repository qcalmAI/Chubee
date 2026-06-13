---
name: docker-compose-services
description: "Add services to the Docker Compose stack on ChubeeAcer (ARM64/GB10). Covers architecture checks, data volume conventions, bind-mount permission fixes (UID-shift pattern), healthcheck patterns per base image, known ARM64 compatibility, and the add-service sequence. Use when adding or troubleshooting any service in ~/chubee/stack/docker-compose.yml."
version: 1.1.0
author: Quinton Calmus
license: MIT
metadata:
  hermes:
    tags: [compose, docker, arm64, stack, permissions, healthcheck]
    related_skills: [vllm-serving, hermes-self-upgrade, hermes-oauth-setup]
---

# Docker Compose Services — ChubeeAcer Stack

Add, update, or troubleshoot services in `~/chubee/stack/docker-compose.yml`.

## Always Do First

1. **Read the compose file** — understand existing structure, ports, volume conventions.
2. **Check available ports** — `ss -tlnp | grep <PORT>` to confirm free.
3. **Verify image architecture** — this is **ARM64 (aarch64)**:
   ```bash
   docker inspect <image>:<tag> --format '{{.Os}}/{{.Architecture}}'
   ```
   If `linux/amd64` and no `linux/arm64` variant exists, it **will not run** without QEMU.

## Conventions

- **Compose file**: `~/chubee/stack/docker-compose.yml`
- **Data volumes**: `/mnt/chubee-data/docker-volumes/<service-name>/`
- **Restart policy**: `unless-stopped`

## Bind-Mount Permissions: Host UID vs Container UID

When a container runs as a **non-1000 UID** and bind-mounts a host directory, files
become inaccessible to the host user `qcalmus` (UID 1000), and vice-versa. The Hermes
gateway is the live example: after v0.16.0 it switched to UID 10000, while `~/.hermes`
is bind-mounted to `/opt/data`.

Symptoms:
- Gateway can't read/write its own files → `Permission denied` on SSH keys
- Host user can't read mounted config/skills → `Permission denied` from SSH shell

**Do NOT fix with `chown -R <UID>:<UID>`** — that locks the other side out.
Use **group ownership**:

```bash
docker exec -u 0 <container> chown -R <containerUID>:1000 /opt/data
docker exec -u 0 <container> find /opt/data -type d -exec chmod 750 {} \;
docker exec -u 0 <container> find /opt/data -type f -exec chmod g+r {} \;
docker exec -u 0 <container> chmod 700 /opt/data/.ssh                     # re-tighten
docker exec -u 0 <container> chmod 600 /opt/data/hermes_ssh_key /opt/data/auth.json
```

Pitfalls within the fix:
- `find` on a SUBTREE misses top-level dirs — verify the full path chain with
  `stat -c '%a %u:%g %n'` on each ancestor.
- `1000` = host user's GID; verify with `id -g` on the host.
- `docker exec <container> whoami` returns `root` (exec defaults to root) — that's NOT
  the runtime user. Check with `id -u <svcuser>` inside the container.
- Always re-tighten secrets AFTER the broad group chmod.

For a full reproduction of the v0.16.0 UID-shift incident, see `references/uid-shift-incident.md`.

### SSH key permission recovery (all tools dead)

When the SSH backend fails with `WARNING: UNPROTECTED PRIVATE KEY FILE! ...
Permissions 0640 for '/opt/data/hermes_ssh_key'` — **every tool is dead**
(terminal, read_file, write_file, patch). The fix must come from the host:

```bash
sudo chmod 600 /home/qcalmus/.hermes/hermes_ssh_key
```

The container path `/opt/data/hermes_ssh_key` does NOT exist on the host —
the host sees `~/.hermes/hermes_ssh_key` which is owned by UID 10000, so
`sudo` is required. `chmod 600 /opt/data/hermes_ssh_key` fails with "No
such file". This exact wrong-path-then-sudo sequence is the recovery.

### hermes vs hermes-dashboard — which container is live?

The stack has TWO containers from the same image: `hermes` (gateway) and
`hermes-dashboard` (dashboard + gateway). Either can stop independently.
Always check which is running before `docker exec`:

```bash
docker ps --format '{{.Names}} {{.Status}}' | grep hermes
```

If `hermes` is "Created" or "Exited" but `hermes-dashboard` is "Up", use
`hermes-dashboard` for all `docker exec` commands — it runs the live
gateway, has the config at `/opt/data/config.yaml`, and has `hermes` CLI.
Both containers share the same `/opt/data` mount, so file operations are
equivalent.

## Healthcheck Patterns

### Critical: Base image determines available tools
Alpine images have `sh`/`wget` but NOT `bash`/`curl`/`/dev/tcp`. Always check first:
```bash
docker run --rm --entrypoint which <image> wget curl nc 2>/dev/null
```

### TCP-based service (bash required — Ubuntu images only)
```yaml
healthcheck:
  test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/localhost/PORT'"]
```

### HTTP service (Alpine — no curl, has wget)
```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -q http://127.0.0.1:PORT -O /dev/null"]
```
**Use `127.0.0.1`, not `localhost`** — Alpine resolves `localhost` to `::1` (IPv6)
while most services bind IPv4 only.

### HTTP service (Ubuntu — has curl)
```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -sf http://localhost:PORT/health || exit 1"]
```

### Fallback (any image with nc)
```yaml
healthcheck:
  test: ["CMD-SHELL", "nc -z localhost PORT"]
```

## Known ARM64 Container Issues (GB10)

| Image | ARM64? | Notes |
|---|---|---|
| Wyoming Whisper (`rhasspy/wyoming-whisper`) | ✅ Exists | CTranslate2 has **no CUDA** — use `--device cpu --compute-type int8` |
| OpenWakeWord (`rhasspy/wyoming-openwakeword`) | ✅ Exists | Works natively |
| Piper TTS (`rhasspy/wyoming-piper`) | ✅ Exists | Preferred TTS; `--voice en_US-lessac-medium` |
| Kokoro Wyoming (`ghcr.io/*/kokoro-wyoming`) | ❌ amd64-only | Use Piper instead |
| Most ML/audio images | ⚠️ Check | `docker inspect --format '{{.Os}}/{{.Architecture}}'` |

`exec format error` at startup = wrong architecture.

## Adding a Service — Step Sequence

1. Create data dir: `mkdir -p /mnt/chubee-data/docker-volumes/<service>/`
2. Verify image architecture compatibility
3. **Inspect ENTRYPOINT and startup script** — many images have wrappers that modify
   flags or environment variables:
   ```bash
   docker inspect <image>:<tag> --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
   docker run --rm --entrypoint cat <image> <path-to-start-sh>
   docker run --rm <image> --help 2>&1 | head -40
   ```
   Caution: some images (e.g. Kiwix) bake `--port=8080` into their startup script —
   passing `--port` in compose duplicates the flag. Use env vars when available.
4. Test-run with `--help` to check CLI flags
5. Add service block to compose file with `patch` tool
6. **After patching, verify YAML** — the `patch` tool can corrupt indentation:
   ```bash
   docker compose -f ~/chubee/stack/docker-compose.yml config > /dev/null
   ```
7. Start: `cd ~/chubee/stack && docker compose up -d <service>` (use
   `background=true` + `notify_on_complete=true` — foreground guard may block
   `up -d`)
8. Check logs: `docker logs <container-name>`
9. Verify health: `docker compose -f ~/chubee/stack/docker-compose.yml ps <service>`

## OAuth Callbacks in Docker: Port Forwarding

When services need OAuth callback listeners inside Docker containers, see
`hermes-oauth-setup` skill (general flow) and `docker-oauth` skill (Spotify-specific).
The port-forward dance is documented there.

## Operational Notes

For incident-specific lessons (`.env` secret trimming, memory saturation from vLLM
reservations, stale docker processes), see `references/operational-notes.md`.
