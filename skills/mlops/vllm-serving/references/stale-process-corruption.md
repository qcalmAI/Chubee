# Stale Process Contamination

**Stale download processes from previous Hermes sessions are the #1 cause of
corrupt model files in a multi-session environment.** When Hermes kills a
long-running background download (SIGTERM after ~3-5 min), the orphaned
`wget`/`curl`/`aria2c` process may persist on the remote SSH host beyond the
session's lifecycle and continue overwriting the target file. On the next
session, the model file looks complete (correct size) but contains corrupted data.

## Diagnosis

Symptoms:
1. **vLLM crashes** with: `safetensors_rust.SafetensorError: Error while deserializing header: incomplete metadata, file not fully covered`
2. **Garbled generation** — model responds with mixed Chinese/English garbage tokens
3. **File size mismatches** — shard reports 3.7 GB but safetensor header expects 3.9 GB

## Kill Pattern (run before ANY model-file operation)

```bash
# Kill ALL stale download/processes referencing model shards
ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
sleep 1
# Second pass for stragglers
ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
# Also kill stale Hermes SSH snap processes
ps aux | grep hermes-snap | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
```

**Run this at the START of every session that touches model files** — not just
when you see corruption. Stale processes are invisible until they overwrite
your good copy.

## Protection Pattern

After copying clean model files from a trusted source, make them read-only:
```bash
chmod a-w /path/to/model-0000*.safetensors
```
**Warning:** vLLM may fail if files are read-only during weight loading. Only
apply after verifying vLLM loads successfully.

## Recovery

1. Kill all stale processes (Kill Pattern above)
2. Restore from a known-good copy (HF cache, backup, or re-download with
   single-connection wget)
3. Validate with safetensor validation script
4. Restart vLLM

**Do NOT copy a single file in isolation** — stale processes may be actively
writing to other shards. Kill first, then restore all.

## Safetensor Validation

```python
import os, struct, json
for f in sorted(os.listdir('.')):
    if not f.endswith('.safetensors'): continue
    sz = os.path.getsize(f)
    with open(f, 'rb') as fh:
        header_len = struct.unpack('<Q', fh.read(8))[0]
        fh.seek(8)
        header_bytes = fh.read(min(header_len, 5_000_000))
        if len(header_bytes) < header_len:
            print(f'  {f}: CORRUPT header truncated')
            continue
    try:
        metadata = json.loads(header_bytes.decode('utf-8'))
        expected_sz = header_len + 8
        for name, info in metadata.items():
            if name == 'metadata': continue
            offsets = info.get('data_offsets', [0,0])
            expected_sz = max(expected_sz, offsets[1] + 8)
        status = 'OK' if sz >= expected_sz - 8 else 'TRUNCATED'
        print(f'  {f}: {status} ({sz/1e9:.1f}GB)')
    except Exception as e:
        print(f'  {f}: CORRUPT header — {str(e)[:80]}')
```

A reusable version: `scripts/validate-safetensors.py`.

## Background Process Persistence

- **SSH connections**: SIGTERM goes to the local Hermes-side wrapper, not the
  remote OS process group. `nohup`-wrapped processes are insulated from SIGHUP.
- **`nohup` escalation**: Long downloads launched with `nohup` fully detach from
  Hermes' lifecycle. They persist after the session ends.
- **Re-spawn**: If Hermes recovers, it may re-create the wrapper and `kill -9`
  the old PID — but a new `nohup` process group with a different PID was already
  started.

Net result: after a model-download session crashes, the remote host may have
1-3 orphaned downloaders slowly writing to the same dir, each corrupting files.
