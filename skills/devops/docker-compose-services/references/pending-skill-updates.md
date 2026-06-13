# docker-compose-services — pending SKILL.md updates

The following sections should be injected before "## Known ARM64 Container Issues"
in the main SKILL.md. Permission wall on the SKILL.md file prevents automated
patching. Fix with:

```bash
docker cp /tmp/dcs-update.md hermes:/opt/data/skills/devops/docker-compose-services/SKILL.md
```

## Critical: `docker restart` Does NOT Re-read Compose

**`docker restart` stops and starts the same container with its original config.**
It does not pick up compose file changes or new images. After any `docker compose
build` or compose edit, always `docker rm -f` then `docker compose up -d`.

This is the #1 cause of "I rebuilt but nothing changed." For the hermes gateway
specifically, see `self-update` skill.

## Container Startup Delays

Some containers take minutes, not seconds. Hermes gateway: 3-4 minutes (ownership
fixup on `/opt/hermes`). vLLM with large models: 3-8 minutes (weight loading +
CUDA graph capture). Do not assume failure until these windows have passed.

## Filebrowser Password Reset

When the admin password is lost: reset via a temp DB copy — the running process
locks the live DB. Full procedure: `references/filebrowser-password-reset.md`.
