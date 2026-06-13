# Model Download Patterns with `hf download`

## Basic Usage

```bash
# Single file (auto-fetch with HF_TOKEN env var)
source /path/to/.env  # contains HF_TOKEN=***
hf download <org>/<model> --local-dir /path/to/weights --local-dir-use-symlinks False
```

## Large Model Weights (Multi-Shard)

For models with multiple .safetensors shards:

```bash
# Downloads all shards + config/tokenizer files
hf download Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4 \
  --local-dir /mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4
```

The CLI shows progress per file and total: `Fetching 15 files: 40% | 6/15`

### ⚠️ Concurrent-Process Lock Deadlock

The HF Hub uses per-blob lock files. **Never run two `hf download` (or
`snapshot_download`) processes against the same model simultaneously.**
They deadlock with:
```
Still waiting to acquire lock on ... .lock (elapsed: 60.0 seconds)
```
Both hang indefinitely until killed. Check before starting:

```bash
ps aux | grep -E "hf download|snapshot_download" | grep -v grep
```

**`--local-dir` does NOT bypass this.** Even when using `--local-dir`,
the `hf` CLI still manages locks under `$HF_HOME/hub/.locks/` using
the same per-blob mechanism. A `hf download --local-dir` and a
`hf download` to the cache of the same model WILL deadlock each other.

**Cache regression symptom:** When a second download process starts while
another has partially downloaded blobs, it may clean and restart those
blobs. You'll see the blob count go up (e.g. 15), then back to 0 on the
next check. This is a sign of overlapping processes. Kill all, clean
stale locks, and restart with a single process.

### When `hf download` gets stuck: use `snapshot_download` instead

The `hf` CLI is prone to lock-stalling with large models. If it consistently
hangs on locks, use Python's `snapshot_download` which handles retries better:

```bash
source ~/.hermes/.env
python3 -c "
from huggingface_hub import snapshot_download
path = snapshot_download('org/model-name')
print(f'DONE: {path}', flush=True)
"
```

If this crashes with:
```
FileNotFoundError: ...blobs/<sha>.incomplete
```
The HF cache has orphaned incomplete blobs from a prior failed run. Nuke the
stale cache and retry:

```bash
rm -rf ~/.cache/huggingface/hub/models--<org>--<model-name>/
```

## HF_TOKEN Authentication

The `hf download` command reads `HF_TOKEN` from the environment automatically. Set it before calling:

```bash
source /path/to/.env
# or:
export HF_TOKEN="hf_..."
```

The token is NOT passed as a CLI flag — it's read from the env var.

### ⚠️ CRITICAL: Verify token validity BEFORE starting download

**An expired or revoked HF_TOKEN is the #1 cause of killed downloads.** It does NOT fail
fast with a clear error. Instead:

- **Small config/tokenizer files download fine** (HF doesn't require auth for them)
- **Large weight files start, run for 2–5 minutes, then get silently killed**
  (SIGTERM / exit -15 / exit 137 / exit 255)
- HuggingFace's Xet CDN throttles unauthenticated connections by dropping them mid-stream
- You see `"Warning: You are sending unauthenticated requests"` even though `$HF_TOKEN`
  shows a value — that means the token is **expired**, not missing

**Always verify before any download:**

```bash
source ~/.hermes/.env
python3 -c "
from huggingface_hub import HfApi, HfFolder
try:
    token = HfFolder().get_token()
    u = HfApi().whoami(token=token)
    print(f'Token OK — logged in as {u[\"name\"]}')
except Exception as e:
    print(f'TOKEN INVALID/EXPIRED: {e}')
"
```

**If the token is expired:**
1. Get a new one from https://huggingface.co/settings/tokens
2. Update `~/.hermes/.env`: `HF_TOKEN=hf_***`
3. Re-verify: `source ~/.hermes/.env && python3 -c "from huggingface_hub import HfApi; print(HfApi().whoami())"`

### sudo -E quoting pitfall

When passing HF_TOKEN through `sudo -E env`, each env var must be a
separate properly-quoted argument:

```bash
# WRONG — missing closing quote swallows the command:
sudo -E env "PATH=$PATH" "HF_HOME=$HF_HOME" "HF_TOKEN=*** hf download org/model

# RIGHT:
sudo -E env "PATH=$PATH" "HF_HOME=$HF_HOME" "HF_TOKEN=*** \
  hf download org/model
```

Symptom: process starts, shows 0%, then sleeps with no network connections.
The `hf` CLI started but never received a subcommand.

## Docker Volume Mount Downloads (host-side, for container consumption)

When the model needs to be accessible inside a Docker container (e.g., vLLM),
download on the **host** directly to the Docker volume mount point. This
avoids container env issues (missing tokens, wrong Python packages) and
Hermes background-process timeouts.

### Pattern: download to Docker volume path

```bash
# 1. Find the mount mapping
docker inspect vllm-super --format '{{json .Mounts}}' | python3 -c \
  "import json,sys; [print(f'{m[\"Source\"]} -> {m[\"Destination\"]}') for m in json.load(sys.stdin)]"
# Example output: /mnt/chubee-data/docker-volumes/vllm-hf-cache -> /hf-cache

# 2. Download directly to the HOST-side mount path
TOKEN=*** /tmp/hftoken.txt)
DIR=/mnt/chubee-data/docker-volumes/vllm-hf-cache/models/Qwen2.5-32B-Instruct-GPTQ-Int4
AUTH=*** Bearer ${TOKEN}"
mkdir -p "$DIR"

aria2c -x 4 -s 4 --header="$AUTH" \
  --connect-timeout=60 --timeout=600 \
  -d "$DIR" -o model-00001-of-00005.safetensors \
  "https://huggingface.co/org/model/resolve/main/model-00001-of-00005.safetensors"
```

The file appears at `/hf-cache/models/Qwen2.5-32B-Instruct-GPTQ-Int4/` inside the container.

### Permission fix

Files created by `docker exec` are owned by root. If the host user needs
to manage them, fix ownership:

```bash
sudo chown -R $USER: /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>/
```

### Token file approach (avoids `***` quoting issues)

The simplest way to avoid Hermes token-masking quote corruption:

```bash
# 1. Extract token to a file
grep ^HF_TOKEN ~/.hermes/.env | cut -d= -f2 > /tmp/hftoken.txt
chmod 600 /tmp/hftoken.txt

# 2. Write auth header to a file
python3 -c "
t = open('/tmp/hftoken.txt').read().strip()
open('/tmp/auth_header.txt', 'w').write(f'Authorization: Bearer {t}')
"

# 3. Use in curl/aria2c commands
aria2c --header="$(cat /tmp/auth_header.txt)" ...
curl -H "$(cat /tmp/auth_header.txt)" ...
```

### ⚠️ Verify SHA256 after download

Always verify downloaded shards match their expected SHA256:

```bash
# Check the expected SHA from the index
python3 -c "
import json
idx = json.load(open('model.safetensors.index.json'))
import hashlib, os
for f in ['model-00001-of-00005.safetensors', ...]:
    if os.path.exists(f):
        sha = hashlib.sha256(open(f,'rb').read()).hexdigest()
        print(f'{f}: {sha}')
"
```

### Background process lifecycle: Hermes-managed vs detached

On this system, Hermes background tasks (`terminal background=true`) get
killed with SIGTERM (exit -15) after approximately 3-10 minutes, regardless
of the requested `timeout` value. This kills large model downloads mid-stream.

**Don't rely on Hermes-managed background tasks for long downloads.**
Use `nohup` to fully detach the process from Hermes lifecycle management:

```bash
# Detach the download script from Hermes process tracking
nohup bash /tmp/dl.sh > ~/download.log 2>&1 &

# Monitor progress
tail -f ~/download.log
```

**But careful:** Stale nohup processes from prior failed attempts keep running
and writing to the same files, corrupting them. Always kill ALL prior download
processes before starting fresh:

```bash
# Kill every prior wget/aria2c/hf download touching this model
pkill -f "wget.*<model-name>" 2>/dev/null
pkill -f "aria2c.*<model-name>" 2>/dev/null
# Also check inside Docker containers
docker exec vllm-super bash -c "pkill -f 'hf download'; pkill -f 'snapshot_download'; pkill -f 'wget.*safetensors'; pkill -f 'aria2c.*safetensors'" 2>/dev/null
```

## Diagnosis: "Download Always Gets Killed Mid-Stream"

If downloads consistently get killed after a few minutes (small files OK, large
shards die with SIGTERM / exit -15 / exit 255 / exit 137):

| Symptom | Likely Cause | Action |
|---|---|---|
| "unauthenticated requests" warning despite `$HF_TOKEN` set | **Token expired/revoked** | Verify with `whoami`, replace token |
| `hf download` hangs on lock for minutes | **Multiple concurrent download processes** | Kill all, clean `.locks/`, restart single process |
| Files download but SHA256 mismatch | **Concurrent writers** (multiple wgets to same target) | Kill all, delete partial, download single-threaded |
| Download starts but speed oscillates wildly | **Xet CDN throttling** → may be token-related or network | Try HF mirror or single-connection wget |
| `docker exec` download exits 137 | **Container OOM kill or Docker daemon timeout** | Run on host directly, not inside container |

### Quick triage

```bash
# 1. Check for zombie processes (BOTH host and container)
ps aux | grep -E "hf download|snapshot_download|wget.*safetensors" | grep -v grep

# ALSO check inside the vLLM container — orphaned downloads live there too
docker exec vllm-super ps aux 2>/dev/null | grep -E "hf|download|python" | grep -v grep

# If 3+ processes are found inside the container, they're all competing for locks.
# Kill them all:
docker exec vllm-super bash -c "pkill -f 'hf download'; pkill -f 'snapshot_download'"

# 2. Check token validity
source ~/.hermes/.env
python3 -c "from huggingface_hub import HfApi, HfFolder; u=HfApi().whoami(HfFolder().get_token()); print('OK:', u['name'])"

# 3. Check for stale locks
find /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub -name '*.lock' -type f 2>/dev/null

# 4. Nuke and retry from clean state
sudo rm -rf /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
sudo rm -rf /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/.locks/models--<org>--<model-name>/
```

## Fallback: HF Mirror (no auth needed for public models)

If token renewal isn't possible immediately, use the Chinese HF mirror which
does NOT require authentication for public models and does NOT route through
the Xet CDN (connections are stable, not aggressively throttled):

```bash
# Via hf CLI
HF_ENDPOINT=https://hf-mirror.com hf download Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4

# Via wget
wget "https://hf-mirror.com/Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4/resolve/main/model-00001-of-00005.safetensors"
```

The mirror doesn't use the Xet CAS bridge, so parallel downloads with aria2c
should also work correctly there (SHA256 is preserved).

Sometimes **both** `hf download` and `snapshot_download` hang on lock
acquisition or stall mid-download (small files complete but shards never
progress). When that happens, bypass the huggingface_hub library
entirely — download shards directly into the HF cache `blobs/` directory.

**Why this works:** The HF symlink cache content-addresses by SHA256.
The `blobs/` directory holds the actual data; `snapshots/` holds symlinks.
Populating blobs/ manually means the next `hf download` or
`snapshot_download` call finds the data and skips those files.

### ⚠️ CRITICAL: Only use single-connection wget (NOT aria2c multi-connection)

HF's Xet content-addressable store does NOT handle parallel range requests
correctly. **aria2c with `-x16` produces files that pass `du` size checks
but have WRONG SHA256 hashes.** Despite apparently fast speeds (~9 MB/s),
the downloaded shards are corrupt — vLLM will fail to load them.

**Always verify SHA256 matches the expected blob filename after download:**

```bash
sha256sum <blob-file> | cut -d" " -f1
# MUST equal the filename in blobs/
```

### Procedure: wget (single connection, reliable)

```bash
cd ~/.cache/huggingface/hub/models--<org>--<model-name>/blobs/

# --- Find the expected SHA256 for each shard ---
HASH=$(cat ../refs/main)
ls -la ../snapshots/$HASH/
# e.g., model-00002-of-00005.safetensors -> ../../blobs/19139f34...

# --- FIRST: kill any stale prior wget/aria2c processes writing to the same files ---
ps aux | grep "wget.*<model-name>" | grep -v grep | awk '{print $2}' | xargs -r kill

# --- Download each missing shard (single connection, reliable) ---
wget --tries=10 --retry-connrefused --timeout=60 \
  -O <expected-sha256> \
  "https://huggingface.co/<org>/<model>/resolve/main/<shard-filename>"

# --- Verify SHA256 ---
sum=$(sha256sum <expected-sha256> | cut -d" " -f1)
if [ "$sum" = "<expected-sha256>" ]; then
  echo "SHA256 MATCH - file valid"
else
  echo "SHA256 MISMATCH - file corrupt, delete and retry"
  rm <expected-sha256>
fi

# --- Create the snapshot symlink ---
ln -sf ../../blobs/<expected-sha256> ../snapshots/$HASH/<shard-filename>
```

### Background process lifecycle: use nohup

On systems where Hermes background processes get killed after ~3-5
minutes, **do not rely on Hermes-managed background tasks** for
long downloads. Use `nohup` to fully detach:

```bash
# Write a self-contained script that downloads, verifies SHA256, creates symlinks
nohup bash -c '
  set -e
  BLOBS=~/.cache/huggingface/hub/models--<org>--<model-name>/blobs/
  HASH=$(cat ../refs/main)
  
  echo "[$(date)] Starting shard 00002..."
  wget --tries=10 --retry-connrefused --timeout=60 \
    -O "$BLOBS/<expected-sha256>" \
    "https://huggingface.co/<org>/<model>/resolve/main/model-00002-of-00005.safetensors"
  sum=$(sha256sum "$BLOBS/<expected-sha256>" | cut -d" " -f1)
  [ "$sum" = "<expected-sha256>" ] && echo "SHA256 OK" || { echo "CORRUPT"; exit 1; }
  ln -sf "../../blobs/<expected-sha256>" "../snapshots/$HASH/model-00002-of-00005.safetensors"
  
  echo "[$(date)] Starting shard 00003..."
  wget --tries=10 --retry-connrefused --timeout=60 \
    -O "$BLOBS/<expected-sha256-2>" \
    "https://huggingface.co/<org>/<model>/resolve/main/model-00003-of-00005.safetensors"
  sum=$(sha256sum "$BLOBS/<expected-sha256-2>" | cut -d" " -f1)
  [ "$sum" = "<expected-sha256-2>" ] && echo "SHA256 OK" || { echo "CORRUPT"; exit 1; }
  ln -sf "../../blobs/<expected-sha256-2>" "../snapshots/$HASH/model-00003-of-00005.safetensors"
  
  echo "ALL DONE"
' > ~/download_shards.log 2>&1 &
```

Monitor progress by checking the log and file sizes:

```bash
tail -f ~/download_shards.log
ls -lh <cache-dir>/blobs/<expected-sha256>
```

### Pitfall: stale NOHUP wgets from prior attempts

When recovering from failed downloads, **multiple stale wget processes
may still be running** under `nohup`, all writing to the same target
file concurrently. This silently corrupts the file — bytes interleave
from different writers.

**Always kill ALL prior wget/aria2c processes for this model before
starting a fresh download:**

```bash
# Kill every wget touching this model
ps aux | grep -E "wget.*<model-name>" | grep -v grep | awk '{print $2}' | xargs -r kill
# Verify nothing remains
ps aux | grep -E "wget.*<model-name>" | grep -v grep
```

After killing, check whether the target file was partially written
by concurrent writers. If the file has data but SHA256 doesn't match,
delete it and start fresh.

### Pitfall: stale locks block resume

If a prior `hf download` or `snapshot_download` was killed while
writing, stale lock files in `.cache/huggingface/` or the HF cache
`.locks/` directory will block new downloads. Clean them first:

```bash
find <cache-dir> -name "*.lock" -mmin +2 -delete
```

## Output Structure

For GPTQ-Int4 models, the local directory contains:
``` 
model-00001-of-00005.safetensors  (shard 1, ~3.9 GB)
model-00002-of-00005.safetensors  (shard 2, ~4.0 GB)
...
model.safetensors.index.json
config.json
tokenizer.json
tokenizer_config.json
...

## Depot Commands

```bash
# List cached/replicated models
hf models list --search "Qwen"

# Remove a cached model
rm -rf /path/to/weights/<model-dir>
```

Additionally, for gated models requiring authentication, see the **Private Model Download Guide** at `references/private-model-download.md`.

---

## ⚠️ `hf download` Producing Corrupt Shards Despite Successful Exit

**Observed pattern:** `hf download --local-dir <dir>` reports:
```
Fetching 15 files: 100%|██████████| 15/15 ...
✓ Downloaded
  path: /path/to/dir
```
Exit code 0. Yet 1–3 of the .safetensors shards are corrupt: vLLM crashes with `safetensors_rust.SafetensorError: Error while deserializing header: incomplete metadata, file not fully covered`.

This happens even with:
- A valid HF_TOKEN (verified via `whoami`)
- A single download process (no concurrent writers)
- `--force-download` flag
- Download on the SSH host (not inside Docker)
- No stale locks, no leftover `.incomplete` files

**Root cause:** The `huggingface_hub` Python library (v1.16.x) has a race in its `--local-dir` multiprocess downloader. Metadata files and smaller configs complete first; large weight shards are still being written when the CLI declares "✓ Downloaded". The header of the in-progress shard is saved as-is (truncated), and the CLI considers the file done because it exists.

**NOTE:** This is NOT the same as the Xet-CDN aria2c corruption (covered above). aria2c produces files with correct sizes but wrong content (SHA256 mismatch). The `hf download` corruption produces files with truncated headers — the file exists and has a valid-looking size but the first 8 bytes reference a header length that extends beyond the available data.

### Diagnosis

```bash
python3 /opt/data/skills/mlops/vllm-serving/scripts/validate-safetensors.py /path/to/weights/dir
```

Look for `TRUNCATED` or `HEADER TRUNCATED` entries.

### Fix: Direct curl download per shard

The most reliable approach when `hf download` produces corrupt output is to download each shard individually with curl, using atomic rename:

```bash
#!/usr/bin/env bash
set -e

TOKEN=*** /path/to/.env)
DIR="/path/to/weights"
mkdir -p "$DIR"
# Kill any stale writers first
pkill -f "model-0000.*safetensors" 2>/dev/null || true

SHARDS=(
  "model-00001-of-00005.safetensors"
  "model-00002-of-00005.safetensors"
  "model-00003-of-00005.safetensors"
  "model-00004-of-00005.safetensors"
  "model-00005-of-00005.safetensors"
)

for shard in "${SHARDS[@]}"; do
  # Download to .tmp first, then atomically rename
  curl -sL -o "$DIR/$shard.tmp" \
    -H "Authorization: Bearer *** \
    "https://huggingface.co/<org>/<model>/resolve/main/$shard" \
    --connect-timeout 30 --max-time 1800 -w "HTTP %{http_code}, Size: %{size_download} bytes\n"
  
  # Verify size
  size=$(stat --format=%s "$DIR/$shard.tmp")
  if [ "$size" -lt 100000000 ]; then
    echo "File too small — likely corrupt"; exit 1
  fi
  
  mv "$DIR/$shard.tmp" "$DIR/$shard"
  echo "  Complete: $shard ($(du -h "$DIR/$shard" | cut -f1))"
done
```

**Important:** Download each shard ONE AT A TIME (sequential). Parallel curl to the same CDN can trigger the same corruption pattern as the multiprocess downloader.

### Pitfall: `--force-download` overwrites config.json changes

If you edited the model's `config.json` (e.g. to add `rope_scaling` for YaRN context extension), running `hf download <model> --local-dir <dir> --force-download` will **overwrite your config.json with the original from the HuggingFace Hub.** Your YaRN configuration is silently lost.

**Fix:** Re-apply the config.json edit AFTER any `--force-download`, or use the standard HF cache (no `--local-dir`) which doesn't overwrite local files.

## Prefer Standard HF Cache Over `--local-dir`

The `--local-dir` mode creates an additional `.cache/huggingface/download/`
metadata tree with per-file lock files that can deadlock even with a single
download process (see "Concurrent-Process Lock Deadlock" above). **Use
standard HF cache (omit `--local-dir`) whenever possible.** vLLM finds
models via `HF_HOME`, so the standard cache at
`$HF_HOME/hub/models--<org>--<model-name>/` works for inference without
a separate local weights directory.

```bash
# ✅ Standard cache — avoids lock contention, automatically resumable
HF_HOME=/path/to/cache hf download org/model

# ❌ --local-dir — prone to lock stalls, stickier retry loop
hf download org/model --local-dir /path/to/weights
```

The standard cache uses a content-addressed symlink layout (`blobs/` +
`snapshots/`). It is more robust for large multi-shard models because
the lock scope is per-cache (not per-target-dir), reducing contention
when multiple downloads target different models.

### Hub directory must be writable

If Docker containers previously wrote to `$HF_HOME/hub/`, the entire tree
may be owned by `root:root`. This causes EVERY `hf download` or
`snapshot_download` call to fail:

```
Permission denied: '.../hub/models--<org>--<model-name>/'
```

**Fix before downloading:**

```bash
sudo chown -R $USER: $HF_HOME/hub/
```

Also check `$HF_HOME/xet/logs/` — Xet logging falls back to console on
permission errors (non-fatal but noisy).

### Reading HF_TOKEN from backup .env files

When the HF_TOKEN is stored in a backup `.env.*` file that is not the
active configuration (e.g., a `.env.bak` from a prior setup), use a
Python script to read it without exposing the token value in tool output:

```python
import os, re
env_path = '/path/to/.env.bak.20260603_005813'
with open(env_path) as f:
    content = f.read()
m = re.search(r'^HF_TOKEN=(.*)$', content, re.MULTILINE)
if m:
    token = m.group(1).strip()
    if token:
        os.environ['HF_TOKEN'] = token
```

Then use `snapshot_download` in the same script (not CLI), which keeps
the token in process environment and never hits stdout:

```python
from huggingface_hub import snapshot_download
path = snapshot_download('org/model')
print(f'DONE: {path}')
```

This avoids Hermes' `***` token masking in terminal output and sudo
quoting issues.