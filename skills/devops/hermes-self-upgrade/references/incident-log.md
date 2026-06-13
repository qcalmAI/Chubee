# Incident Log — hermes-self-upgrade

## v0.15.1 → v0.16.0 (2026-06-07)

### UID shift (gosu → s6-setuidgid)
Upstream dropped `gosu` for `s6-setuidgid`, changing runtime user from UID 1000
to UID 10000. Every file under `/opt/data` created as uid 1000 became inaccessible.
SSH backend died with `Permission denied` on keys.

Fix: group ownership (10000:1000) + group-read perms. Full procedure in
`docker-compose-services` skill, `references/uid-shift-incident.md`.

### Clean compose auto-merge produced a Frankenstein
Both fork and upstream edited the gateway service. Git auto-combined non-overlapping
hunks — the fork's workaround volume AND upstream's new structure both present.
Always diff merged compose against pure upstream.

### Foreground build timeout
`docker compose build gateway` took 8+ min. Foreground tool timed out at 180s.
Backgrounded it; verified final image id.

### `hermes status` box omits version
User saw same version number pre/post upgrade because `hermes status` doesn't show
version. `hermes --version` confirmed the move.

### Two competing builds writing one log file
Timed-out foreground build + background build raced on the same log file. Log looked
stale but the image had been written. Always check the image id, not just the log tail.

### calver vs semver jump
Upstream switched version schemes (0.15.1 → 0.16.0/2026.6.5). Tags and pyproject
disagreed; pyproject is authoritative.

### Git identity not set on fresh box
`git commit` failed with "Author identity unknown." Required `git config user.email/name`.

### `git commit --no-edit` after already-completed merge
Nothing staged → aborted on empty message. Stage post-merge edits and use `-m`.

### Stray `.bak.s6fix.<ts>` files
Hermes's own `/update` auto-stash backups — harmless but show as untracked.
`rm -f` before committing.

## Survival model: why external Claude was chosen over watchdog scripts

A detached watchdog script that auto-rolls-back on timeout is more brittle than a
human operator with a briefing. The external Claude caught the UID-shift regression
(a novel bug the script couldn't have anticipated) and applied the group-ownership
fix. A script would have timed out, rolled back, and left the problem for next time.

The external-operator model: the agent does everything safe (merge, build), writes
a one-shot briefing, and hands off. The operator runs cutover, checks health, and
escalates to the user only if something goes wrong.
