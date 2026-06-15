# Systematic ChubeeAcer Audit Methodology

How to do a full-system audit without breaking anything. Proven during the 2026-06-15 spring cleaning.

## Principles

1. **Map before you touch.** Breadth-first exploration: list directories, measure sizes, check ownership BEFORE reading files or making changes.
2. **Prove assumptions with direct observation.** "Both containers are running" doesn't tell you which one is live. Map PIDs to ports, cross-reference with `docker inspect`, check file contents inside each container.
3. **Never recommend deletion without verification.** Before suggesting `docker stop X`, prove X is not the live container. Before suggesting `docker rmi Y`, prove Y is not referenced by the compose file.
4. **Commit before cleaning.** `git commit` the working state so you can roll back any file deletion.

## The systematic exploration sequence

### Layer 0: Host overview (SSH)
```bash
ssh qcalmus@100.65.206.99
ls -la ~/
df -h /mnt/chubee-data
```

### Layer 1: Container inventory
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker ps -a  # also show stopped containers
```

### Layer 2: Port-to-process mapping
```bash
sudo ss -tlnp | grep -E '9119|8000|9000'
```
Cross-reference the PID with `docker inspect <container> --format '{{.State.Pid}}'` to confirm which container owns each port.

### Layer 3: Compose vs reality
```bash
cd ~/chubee/stack && docker compose config --services  # what SHOULD be running
docker compose config 2>&1 | grep 'image:' | sort -u   # what images are referenced
```
Compare against `docker images` to find stale images. Any image NOT in the compose output is a deletion candidate.

### Layer 4: Service-specific probes
```bash
# vLLM: what models are loaded?
curl -s http://localhost:8000/v1/models | python3 -m json.tool

# Ollama: what models?
curl -s http://localhost:11434/api/tags | python3 -m json.tool

# Hermes: state and model config
docker exec hermes-dashboard cat /opt/data/gateway_state.json
docker exec hermes-dashboard grep -A3 'default:' /opt/data/config.yaml
```

### Layer 5: Git state (both repos)
```bash
cd ~/hermes-agent && git status --short && git branch && git log --oneline -3
cd ~/chubee && git status --short && git branch
```

### Layer 6: Data directory audit
Check from inside the container (host user can't read UID-10000 files):
```bash
docker exec hermes-dashboard ls -la /opt/data/
docker exec hermes-dashboard du -sh /opt/data/sessions/ /opt/data/logs/ /opt/data/skills/
```

### Layer 7: Docker image audit
```bash
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
```
Cross-reference each image against the compose file (Layer 3). Images not referenced and not parent images of referenced images are stale.

## Destructive operations: the safety sequence

1. **Identify** what to delete
2. **Prove** it's safe (not live, not referenced, not a parent image)
3. **Commit** git state for rollback
4. **Execute** the deletion
5. **Verify** the system still works

**Do NOT batch cp-then-rm in a single ssh command** — if the `rm` runs before the `cp` completes, data is lost. Use separate commands and verify the copy succeeded before deleting the source.

## The "is this really live?" container test

When two containers share a mount and both appear "Up":
```bash
# 1. Which PID binds the dashboard port?
sudo ss -tlnp | grep 9119
# => LISTEN 0 2048 0.0.0.0:9119 users:(("hermes",pid=937025,fd=6))

# 2. Which container owns that PID?
docker inspect hermes --format '{{.State.Pid}}'
docker inspect hermes-dashboard --format '{{.State.Pid}}'
# Match against the PID from ss output

# 3. KEEP the container that owns 9119. STOP the other.
docker stop <the-wrong-one>
```

## The "trophies on a shelf" model storage pattern

The user's explicit preference: model tarballs should be isolated offline archives, NOT referenced by any running service (vLLM, Ollama, Hermes config). Each tarball is ONE self-contained file with everything needed to run that model. They exist as a hedge against future regulatory risk (open-source models potentially becoming illegal). 

Storage: `/mnt/chubee-data/<Model-Name>.tar` or `.tar.gz`
Hermes config: NO entries referencing trophy models
vLLM: only serves the live model, not the trophies
Ollama: no trophy model entries

The live model (Nemotron Nano-30B) lives in the HuggingFace cache, NOT as a tarball — it's the running model and must never be archived/purged.
