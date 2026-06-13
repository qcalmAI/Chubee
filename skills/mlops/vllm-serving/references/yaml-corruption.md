# Docker Compose YAML Corruption from Repeated Patching

## Symptom

Docker Compose refuses to start with a confusing error:
```
'services[vllm-super].extra_hosts' invalid additional host, missing IP: --kv-cache-dtype
```
Or a `command:`-list value appears embedded in a different YAML key far from it.

## Root Cause

Repeated `patch` tool calls on a YAML file can destabilize the structure:

1. **Stale progress bars / ANSI output** — The `patch` tool reads the file on
   disk, but a concurrently-running background process may have temporarily written
   partial content. Patch applies to stale content → corruption.
2. **Uncommented remnants** — Converting an active service to a commented-out
   template, the `patch` tool may miss commenting a few lines. These bare YAML
   list items float with no parent key, getting absorbed into the nearest sibling.
3. **Duplicate lines from fuzzy matching** — The `patch` tool's fuzzy matching can
   match the wrong occurrence when there are two similar blocks.

## Diagnosis

```bash
# YAML syntax check
docker compose -f docker-compose.yml config 2>&1

# Search for uncommented lines in commented-out sections:
grep -n "^    - " docker-compose.yml | head -30
```

Any uncommented list item (`- value`) in a comment block is a red flag.

## Fix

1. Scan the full file for uncommented lines in commented blocks
2. Use `patch` with unique context — include surrounding commented lines
3. Or rewrite the block entirely with `write_file` (exact control)

```bash
# Quick fix: comment orphaned lines
sed -i '/^    - --kv-cache-dtype/s/^/  # /' docker-compose.yml
sed -i '/^    - fp8$/s/^/  # /' docker-compose.yml
```

## Prevention

- **Verify YAML after every 3 patches** — run `docker compose -f <file> config`
- **When restructuring (active ↔ commented), prefer `write_file`** for the full
  block rather than 4-5 sequential patches
- **Avoid leaving orphaned list items** when commenting out a service
- **Run the Kill Pattern before editing configs** — never assume disk state is
  quiescent
