# HF Model Download to Docker Volumes for vLLM

Downloading large LLM weights (15-50+ GB) to a Docker volume that vLLM can
access involves several recurring failure modes. This reference captures the
reliable workflow and common pitfalls.

## Target Layout

The Docker volume is mounted into the vLLM container at `/hf-cache`, and
`HF_HOME=/hf-cache` is set. vLLM resolves model IDs via the HuggingFace cache
under that path:

```
/mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
├── blobs/           # actual file content, content-addressed
├── refs/            # symlink by branch/tag name
├── snapshots/       # directory per commit with symlinks into blobs/
└── .locks/          # per-blob lock files (source of stuck-download hell)
```

## Reliable Download Approach

### 0. Never run two downloads concurrently

The HuggingFace Hub uses per-blob lock files (`/hf-cache/hub/.locks/models--<org>--<model-name>/*.lock`).
**If two `hf download` or `snapshot_download` processes run at the same time against the
same model cache, they deadlock.** Both get stuck printing:
```
Still waiting to acquire lock on ... .lock (elapsed: 60.0 seconds)
```
They will wait forever until killed.

**`--local-dir` does NOT bypass this.** Even with `--local-dir`, `hf download`
still uses lock files under `$HF_HOME/hub/.locks/` for the same model. A
`--local-dir` download and a cache download of the same model WILL deadlock.

**Cache regression symptom:** If blobs count goes up (e.g. 15) then back to 0,
a second overlapping process cleaned and restarted partial shards. Kill all,
clean locks, restart with a single process.

Always check for existing downloads first:

```bash
ps aux | grep -E "hf download|snapshot_download" | grep -v grep
```

If one is already running, either wait for it or kill it before starting a new one.

### 1. Clean state before starting

Interrupted downloads leave stale `.locks/` and orphaned `.incomplete` blobs
that cause `FileNotFoundError` crashes even in `snapshot_download`. Clean all
relevant paths:

```bash
TARGET_DIR=/mnt/chubee-data/docker-volumes/vllm-hf-cache
sudo rm -rf "$TARGET_DIR"/hub/models--<org>--<model-name>/
sudo rm -rf "$TARGET_DIR"/hub/.locks/models--<org>--<model-name>/
rm -rf ~/.cache/huggingface/hub/models--<org>--<model-name>/
rm -rf ~/.cache/huggingface/hub/.locks/models--<org>--<model-name>/
```

**Verification:** After cleaning, confirm no stale cache remains:
```bash
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/ | grep <model> || echo "Nothing to clean"
```

### 2. Download via Python to user cache, then copy (most reliable)

The `hf` CLI has lock-consistency issues with large models. `snapshot_download`
from Python is more robust:

```bash
source ~/.hermes/.env          # provides HF_TOKEN
export HF_TOKEN

# Download to user's cache (faster, avoids permission issues)
timeout 7200 python3 -c "
from huggingface_hub import snapshot_download
import os
os.environ['HF_HOME'] = os.path.expanduser('~/.cache/huggingface')
print(f'Token set: {bool(os.environ.get(\\\"HF_TOKEN\\\"))}', flush=True)
path = snapshot_download('<org>/<model-name>')
print(f'DONE: {path}', flush=True)
"
```

This downloads to `~/.cache/huggingface/hub/`. After it completes, copy to the
Docker volume:

```bash
sudo cp -a ~/.cache/huggingface/hub/models--<org>--<model-name> \
  /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/
sudo chown -R root:root /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
```

Verify from inside the container:
```bash
docker exec vllm-super ls /hf-cache/hub/ | grep <model>
docker exec vllm-super du -sh /hf-cache/hub/models--<org>--<model-name>/
```

### 3. Alternative: Download directly into vLLM container via `docker exec` + `snapshot_download`

When the container is already running vLLM, you can download straight to its
`/hf-cache` volume without a copy step. Use Python `snapshot_download`, *not*
the `hf` CLI — the CLI is more prone to lock-stalling inside the container.

```bash
source ~/.hermes/.env
docker exec -e HF_TOKEN=*** vllm-super bash -c '
python3 -c "
from huggingface_hub import snapshot_download
import os
os.environ[\"HF_HOME\"] = \"/hf-cache\"
path = snapshot_download(\"<org>/<model-name>\")
print(f\"DONE: {path}\", flush=True)
"
'
```

**Notes:**
- Pass `HF_TOKEN` via `-e` flag — `/hermes-env` does not exist inside the container
- `os.environ["HF_HOME"] = "/hf-cache"` is only needed if the container doesn't
  already have `HF_HOME` set in its env
- **Do NOT use `hf download` inside the container** — it gets stuck on lock
  contention with itself (the locks don't auto-release fast enough)
- `snapshot_download` handles retries and lock acquisition better than the CLI

**Cache corruption recovery during this approach:** If `snapshot_download` crashes with:
```
FileNotFoundError: [Errno 2] No such file or directory: '...blobs/<sha>.incomplete'
```
The HF cache has orphaned incomplete blobs from a prior failed run. Nuke and retry:
```bash
docker exec vllm-super rm -rf /hf-cache/hub/models--<org>--<model-name>/
```

Then re-run the `docker exec` command above.

### 4. Alternative: Download via `hf` CLI straight to volume

```bash
# sudo is required because Docker volumes are owned by root
# The user's .local/bin/hf is not in root's PATH, so preserve it
source ~/.hermes/.env
sudo -E env "PATH=$PATH" HF_HOME=/mnt/chubee-data/docker-volumes/vllm-hf-cache \
  HF_TOKEN=*** hf download <org>/<model-name>
```

**But this can get stuck on locks** if a previous download was interrupted.
Prefer the Python + copy approach.

### 6. Emergency fallback: `wget -c` directly into the HF cache blobs/

When **both** `hf download` and `snapshot_download` consistently hang on lock
acquisition (even after clean-state restarts), bypass the huggingface_hub
library entirely. Download the shard files directly with `wget -c` into the
HF cache's `blobs/` directory, verify SHA256, and create the symlinks.

This is the nuclear option — use only when the library-based approaches
repeatedly fail on lock contention or token validation.

**Step 1 — Determine what's missing**

```bash
SNAPSHOT_DIR=~/.cache/huggingface/hub/models--<org>--<model-name>/snapshots/<hash>
ls -la "$SNAPSHOT_DIR"/
```

Files shown as symlinks exist. Files not shown need to be downloaded.
The snapshot hash is in `refs/main`:
```bash
cat ~/.cache/huggingface/hub/models--<org>--<model-name>/refs/main
```

**Step 2 — Download each missing shard with wget**

```bash
cd ~/.cache/huggingface/hub/models--<org>--<model-name>/blobs/

# Download with resume (wget -c)
wget -c -O <expected-sha256> \
  "https://huggingface.co/<org>/<model>/resolve/main/model-000XX-of-000YY.safetensors"
```

The expected SHA256 hash is determined by looking at the model's
`model.safetensors.index.json` or by pattern-matching from the model listing.
On HuggingFace, navigate to the model page, find the file listing, and
copy the shard URL pattern.

**Step 3 — Verify SHA256 and create symlink**

```bash
# Verify the downloaded file matches the expected blob hash
echo "<expected-sha256>  <expected-sha256>" | sha256sum -c

# Create the snapshot symlink
ln -sf ../../blobs/<expected-sha256> \
  ~/.cache/huggingface/hub/models--<org>--<model-name>/snapshots/<hash>/model-000XX-of-000YY.safetensors
```

**Step 4 — Verify the cache is complete**

```bash
ls ~/.cache/huggingface/hub/models--<org>--<model-name>/snapshots/<hash>/ | grep safetensors
# Should show all 5 (or N) shards
```

**Step 5 — Copy to Docker volume (if needed)**

```bash
sudo cp -a ~/.cache/huggingface/hub/models--<org>--<model-name> \
  /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/
sudo chown -R root:root /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
```

**How it works:** The HF symlink cache stores content-addressable blobs. Each
file in `snapshots/` is a symlink to `../../blobs/<sha256-of-content>`. If the
blobs already exist (even partially), `snapshot_download` detects them. If the
huggingface_hub library won't cooperate, you can populate the blobs/ directory
manually and the library recognizes them on the next `snapshot_download` call
(with `resume_download=True`).

**When wget is slow:** Without a valid HF_TOKEN, `wget` is rate-limited to
~200 KB/s. A 3.9 GB shard takes ~5.5 hours. This is still better than a
library that hangs forever. With a valid token, `wget` gets the same
~3 MB/s as `hf download`.

## Authentication

- **With HF_TOKEN**: ~3 MB/s download speed (no rate limiting on large files)
- **Without HF_TOKEN**: Rate-limited by HuggingFace (~200 KB/s). Large files (>1 GB) stall
  or progress very slowly
- Set the token: `HF_TOKEN=***                ~/.hermes/.env`

### Verify token validity BEFORE starting a large download

A stored token may be expired or revoked. Don't learn this after 30 minutes of slow download.

```bash
source ~/.hermes/.env
python3 -c "
from huggingface_hub import HfApi
try:
    user = HfApi().whoami(token=HfApi().get_token())
    print(f'Token OK — logged in as {user[\"name\"]}')
except Exception as e:
    print(f'Token INVALID: {e}')
"
```

If the token is invalid:
1. Go to https://huggingface.co/settings/tokens and generate a new `read` token
2. Update the env file: `nano ~/.hermes/.env` and replace the HF_TOKEN value
3. Re-run the verification above before starting the download

Symptom of invalid token: "Warning: You are sending unauthenticated requests to the HF Hub"
even though `echo $HF_TOKEN` shows a value.

### sudo -E env quoting pitfall

When passing HF_TOKEN through `sudo -E env`, every env var must be a
separate properly-quoted argument. The most common mistake is a missing
closing quote that swallows the command:

```bash
# WRONG — the missing closing quote on HF_TOKEN swallows 'hf download ...'
# as part of the env var value, so the command never actually runs:
sudo -E env "PATH=$PATH" "HF_HOME=$HF_HOME" "HF_TOKEN=*** hf download org/model

# RIGHT — each env var is a properly-terminated separate argument:
source ~/.hermes/.env
sudo -E env "PATH=$PATH" "HF_HOME=$HF_HOME" "HF_TOKEN=*** \
  hf download org/model
```

Symptom: the process starts, shows 0% progress briefly, then goes to sleep
with no network connections and no output. The `hf` CLI started but never
received a subcommand because the subcommand was eaten by the env value.

## Download Dimensions

| Model | Size | Time at 3 MB/s |
|---|---|---|
| Qwen2.5-32B-Instruct-GPTQ-Int4 | ~17 GB | ~1.5 hours |
| Nemotron-3-Nano-30B-A3B-FP8 | ~30 GB | ~2.5 hours |
| Nemotron-3-Super-120B-A12B-NVFP4 | ~75 GB | ~7 hours |

## Stuck Download Recovery

Symptom: `Still waiting to acquire lock on .../.locks/...` for 60+ seconds.

### 1. Find ALL orphaned download processes

Multiple downloads may be running inside the vLLM container from prior failed
attempts — `pkill -f` on the host does NOT reach them:

```bash
docker exec vllm-super ps aux | grep -E "hf|python|download" | grep -v grep
```

If you see 3+ `hf download` or `snapshot_download` processes, they're all
fighting over the same lock files. Kill them all at once:

```bash
# Kill from host
pkill -f "hf download" 2>/dev/null
pkill -f "snapshot_download" 2>/dev/null

# Kill inside container
docker exec vllm-super bash -c "pkill -f 'hf download'; pkill -f 'snapshot_download'"

# Also check for orphaned Python processes from docker exec
docker exec vllm-super ps aux | awk '/python.*hf|python.*download/{print $2}' | xargs -r kill 2>/dev/null
```

**Key insight:** `pkill -f` on the HOST does not kill processes running INSIDE
a Docker container. You must `docker exec <container> pkill` to reach them.
Orphaned container-side downloads are the #1 cause of recurring lock
contention — you can clean the `.locks/` directory five times and it won't
help if an orphan is still running and recreating them.

### 2. Clean locks and data

```bash
# Clean vLLM container cache
docker exec vllm-super rm -rf /hf-cache/hub/models--<org>--<model-name>/
docker exec vllm-super rm -rf /hf-cache/hub/.locks/models--<org>--<model-name>/

# Clean host cache
rm -rf ~/.cache/huggingface/hub/models--<org>--<model-name>/
rm -rf ~/.cache/huggingface/hub/.locks/models--<org>--<model-name>/
```

### 3. Verify no processes remain

```bash
docker exec vllm-super ps aux | grep -c "hf download" 2>/dev/null || echo "0"
# Should output 0 or nothing
```

### 4. Restart with a single clean download

Use one of the reliable approaches below — never start two downloads
concurrently.

## Verification

After download, check the Docker volume has the model:

```bash
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/ | grep <model>
echo "Snapshot files:"
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/snapshots/*/ 2>/dev/null | head -20
sudo du -sh /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
```

From inside the container:

```bash
docker exec vllm-super ls /hf-cache/hub/ | grep <model>
```

## Alternative: Direct Download to Docker Volume (Bypasses HF Cache Entirely)

For the cleanest approach that avoids **ALL** HF cache lock contention, download
directly to a local directory on the docker volume mount and point vLLM at that
path. This stores the model as plain files (no symlinks, no `.locks/`, no
`blobs/` structure).

### Target directory

```bash
# Host path (what we download to)
HOST_DIR=/mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<org>--<model-name>

# Container path (what vLLM sees)
# /hf-cache/models/<org>--<model-name>
```

Mounted as `/hf-cache/models/` inside the container.

### The reliable workflow

**Step 1 — Fix permissions first (critical)**

The Docker volume is owned by root. User-space tools can't write to it:

```bash
sudo mkdir -p /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
sudo chown $USER: /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
```

**Step 2 — Download with `snapshot_download` + `local_dir`**

```bash
source ~/.hermes/.env
export HF_TOKEN
python3 -c "
from huggingface_hub import snapshot_download
import os
os.environ['HF_HOME'] = '/tmp/hf_cache_clean'  # unique path, no stale locks
os.environ['HF_HUB_DOWNLOAD_TIMEOUT'] = '7200'
path = snapshot_download(
    '<org>/<model>',
    local_dir='/mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>',
)
print(f'DONE: {path}', flush=True)
"
```

`local_dir` bypasses the HF symlink cache entirely. Files are written directly
to the target directory as plain files — no `blobs/`, no `.locks/`, no
`snapshots/`. This is the most reliable approach for multi-shard models.

**Pitfall:** `local_dir_use_symlinks=False` and `resume_download=True` are
deprecated/ignored in current `huggingface_hub` — the library always copies and
always resumes when possible. Just pass `local_dir`.

**Step 3 — (Optional) Copy to HF cache if vLLM expects cache path**

If vLLM is configured to find models by name (not path), copy the files into
the HF cache after download:

```bash
sudo cp -a /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name> \
  /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/
```

But vLLM can also load directly from a path:

```bash
vllm serve /hf-cache/models/<model-name> --served-model-name <model-name> ...
```

### Pitfalls

- **Directories must be writable by your user** — Docker volumes are root-owned.
  Always `sudo chown $USER:` the target before downloading.
- **`local_dir_use_symlinks=False` and `resume_download=True` are deprecated**
  in current `huggingface_hub` (the library issues warnings). Downloads always
  copy files and always resume. Don't pass these args.
- **Permission errors on `.cache/` subdirectory** are benign — `huggingface_hub`
  creates temp files for caching inside `local_dir/.cache/`. If this directory
  is root-owned, you'll see "Could not set the permissions" warnings but the
  download proceeds. You can suppress by pre-creating `.cache` with correct
  permissions.
- **This approach uses more disk temporarily** — `snapshot_download` with
  `local_dir` downloads into `local_dir/.cache/huggingface/download/` first,
  then moves completed files to `local_dir`. The `.cache` dir acts as a temp
  download buffer. At peak, you may see 2× the final size briefly (before
  incomplete files are moved).
- **snapshot_download may silently exit after small files** — if the process
  only downloads the 6 config/tokenizer files (40%) and stops, it likely hit
  a permission error on `.cache/huggingface/download/` and couldn't proceed
  with the weight shards. Use `aria2c` directly for the weight shards instead.

### Direct Aria2c Download to Docker Volume (Fallback)

When `snapshot_download` consistently fails on permission/cache issues, download
each weight shard directly with `aria2c`. This bypasses ALL HF cache mechanisms.

**Step 1 — Setup**

```bash
# Extract token to file (avoids quoting issues)
grep HF_TOKEN ~/.hermes/.env | cut -d= -f2 > /tmp/hftoken.txt && chmod 600 /tmp/hftoken.txt

# Create target dir with correct permissions
sudo mkdir -p /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
sudo chown $USER: /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
```

**Step 2 — Generate script via Python (avoids bash quoting corruption)**

```bash
python3 << 'PYEOF'
token = open('/tmp/hftoken.txt').read().strip()
DIR = "/mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>"
script = f'''#!/bin/bash
AUTH="Authorization: Bearer {token}"
for i in 1 2 3 4 5; do
  F="model-0000${{i}}-of-00005.safetensors"
  echo "--- Shard $i: $F ---"
  aria2c -x 4 -s 4 \\
    --header="$AUTH" \\
    --connect-timeout=60 --timeout=600 \\
    --max-connection-per-server=4 \\
    --console-log-level=notice \\
    -d "{DIR}" -o "$F" \\
    "https://huggingface.co/<org>/<model>/resolve/main/$F"
  echo "Done: $(ls -lh "{DIR}/$F" | awk '{{print $5}}')"
done
echo "=== ALL DONE ==="
'''
with open('/tmp/dl.sh', 'w') as f:
    f.write(script)
import os; os.chmod('/tmp/dl.sh', 0o755)
PYEOF
```

**Key design choices:**
- `AUTH=*** Bearer {token}"` stores the auth header in a bash variable,
  avoiding inline quote-escaping issues
- The Python heredoc (`<< 'PYEOF'`) prevents shell expansion of `$` in the
  template
- Python f-string interpolates the token value safely
- The script's inner for-loop uses `${{i}}` (escaped braces) so bash sees `${i}`

**Step 3 — Run**

```bash
# Run in background — each 3.7 GB shard takes ~15-20 min at 3-4 MB/s
bash /tmp/dl.sh
```

**Step 4 — Verify**

```bash
ls -lh /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>/model-0000*.safetensors
```

**Performance notes:**
- `aria2c -x 4 -s 4` uses 4 parallel connections per shard
- Download speed averages 3-4 MB/s (varies 0.5-8 MB/s depending on HF CDN)
- Each ~3.7 GB shard takes 15-20 minutes
- All 5 shards (~19 GB) takes about 1.5-2 hours total
- Don't use `--allow-overwrite=true` — it triggers re-download of existing shards
- Background tasks may get SIGTERM after 7-10 minutes from the terminal tool's
  process manager. If interrupted, re-run the script — aria2c resumes by default
  for partial files

### Permission Fix Pattern

Before any download to a Docker volume, always:

```bash
# Check who owns the target
ls -ld /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/

# Fix if root-owned
sudo mkdir -p /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
sudo chown $USER: /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/
sudo chown $USER: /mnt/chubee-data/docker-volumes/vllm-hf-cache/models/<model-name>
```

Forgetting this step causes:
- `PermissionError: [Errno 13] Permission denied` from Python
- Curl silent failures (0 bytes written)
- `snapshot_download` silently exit after config files

## Hermes Token Quoting Workaround

When writing scripts that use `HF_TOKEN` from `~/.hermes/.env`, Hermes' `***`
masking breaks inline bash quoting. The `***` placeholder gets substituted in
ways that corrupt quote boundaries.

### The problem

```bash
# This DOES NOT work reliably — Hermes masking corrupts quotes:
source ~/.hermes/.env && curl -H "Authorization: Bearer *** ...
```

### Solutions

**A) Token file extraction (simplest)**

```bash
# Extract token to a file once at session start
grep HF_TOKEN ~/.hermes/.env | cut -d= -f2 > /tmp/hftoken.txt && chmod 600 /tmp/hftoken.txt

# Read from file in scripts
curl -H "Authorization: Bearer *** ..." ...
```

**B) Python-generated bash scripts (most robust)**

```bash
python3 << 'PYEOF'
token = open('/tmp/hftoken.txt').read().strip()
script = f'''#!/bin/bash
AUTH="Authorization: Bearer {token}"
aria2c --header="$AUTH" ...  # Use variable, not inline expansion
'''
with open('/tmp/dl.sh', 'w') as f:
    f.write(script)
PYEOF
```

The Python heredoc (`<< 'PYEOF'` with single quotes) prevents shell expansion
of `$` in the heredoc body, while Python's f-string interpolation correctly
embeds the token value.

**C) Direct `docker exec -e HF_TOKEN` (for vLLM container)**

```bash
source ~/.hermes/.env
docker exec -e HF_TOKEN vllm-super python3 -c "
from huggingface_hub import snapshot_download
path = snapshot_download('org/model')
print(f'DONE: {path}')
"
```

The `-e HF_TOKEN` (without `=value`) copies the variable from the docker
client's environment into the container.

## Download with aria2c (fast but may corrupt on HF Xet CDN)

`aria2c` with `-x 4` downloads at 3-4 MB/s per shard (~20 min per 3.7 GB shard).
However, **HF's Xet content-addressable store may NOT handle parallel range
requests correctly** — SHA256 verification after download may mismatch.

If you use aria2c:
- Always verify SHA256 afterward
- Prefer single-connection wget for critical models
- hf-mirror.com does not use Xet CDN, so aria2c works correctly there

```bash
aria2c -x 4 -s 4 \
  --header="Authorization: Bearer *** \
  -d "$DIR" -o "shard.safetensors" \
  "https://huggingface.co/org/model/resolve/main/shard.safetensors"
```

```bash
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/ | grep <model>
echo "Snapshot files:"
ls /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/snapshots/*/ 2>/dev/null | head -20
sudo du -sh /mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--<org>--<model-name>/
```

From inside the container:

```bash
docker exec vllm-super ls /hf-cache/hub/ | grep <model>
```

## Pitfalls

### Stale Process Contamination (Multi-Session Killer)

**The most insidious failure mode for large model downloads:** When a Hermes session launches a download via `terminal(background=True, ...)` and the session ends (timeout, crash, `/quit`), the background process on the remote SSH host may **persist** and continue writing to the target file. On the next session, you see a file that looks complete (correct size) but was overwritten mid-stream by the orphaned process.

Symptoms:
- vLLM fails to load: `safetensors_rust.SafetensorError: Error while deserializing header: incomplete metadata, file not fully covered`
- vLLM starts but produces garbled Chinese/English output (BPE tokens decoded against wrong vocabulary)
- File sizes look correct but safetensor header validation shows truncation

**Always kill stale processes before any file operation:**

```bash
# Kill ALL stale download/stale processes referencing any model shard
ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null

# Also kill stale Hermes SSH snap processes
ps aux | grep hermes-snap | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
```

**After copying clean files from HF cache, also make them read-only** as a safeguard:

```bash
chmod a-w /path/to/model-0000*.safetensors
```

### Other Pitfalls

- **Do NOT run `hf download` while a previous one is still alive** — the lock
  mechanism is per-blob, not per-process, and orphaned locks persist on kill
- **Do NOT use `huggingface-cli`** — it's deprecated and errors immediately
- **Docker volumes owned by root** — use `sudo` or copy via host, don't try to
  `docker exec` and download from inside the container (competing for GPU
  memory if the container is already running vLLM)
- **HF_TOKEN from .env** — `source ~/.hermes/.env` works; passing via
  `sudo -E env "PATH=$PATH"` is the safest way to preserve it for root
- **Timeouts** — large models need 2+ hours of timeout. Use `timeout 7200`
