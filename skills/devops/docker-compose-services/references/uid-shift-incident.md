# UID-Shift Permission Incident (v0.15.1 → v0.16.0)

## What happened

Upstream Hermes dropped `gosu` for `s6-setuidgid` in v0.16.0, changing the gateway
runtime user from UID 1000 to UID 10000 (`HERMES_UID`). Every file under `/opt/data`
created as uid 1000 that the gateway must WRITE became inaccessible.

Symptom after cutover: SSH terminal backend died with:
- `Load key "/opt/data/hermes_ssh_key": Permission denied`
- `Failed to add the host to the list of known_hosts`

## Fix (applied post-cutover from an external Claude session)

```bash
docker exec -u 0 hermes chown -R 10000:1000 /opt/data      # gateway owns, host group
docker exec -u 0 hermes find /opt/data -type d -exec chmod 750 {} \;
docker exec -u 0 hermes find /opt/data -type f -exec chmod g+r {} \;
docker exec -u 0 hermes chmod 700 /opt/data/.ssh
docker exec -u 0 hermes chmod 600 /opt/data/hermes_ssh_key /opt/data/.ssh/known_hosts /opt/data/auth.json
```

## Why `chown -R 10000:10000` is wrong

A blunt `chown -R 10000:10000` satisfies the gateway but LOCKS THE HOST USER OUT.
The host user `qcalmus` (UID 1000) can no longer read `~/.hermes/` from an SSH shell
— can't check config, can't read skills, can't verify anything. Group ownership
(10000:1000) with group-read perms lets BOTH the gateway (UID 10000) and host
user (GID 1000) access.

## Re-tighten secrets after broad chmod

A `find ... -exec chmod g+r {} \;` makes private keys group-readable. Always
re-tighten with targeted `chmod 600` on secrets AFTER the broad sweep.
