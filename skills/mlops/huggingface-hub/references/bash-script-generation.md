# Generating Bash Download Scripts via Python Heredoc

When using Hermes to download large HF models, inline bash commands that
reference `$HF_TOKEN` or `$TOKEN` often get corrupted by Hermes' sensitive-data
masking — the actual token value gets replaced with `***` in the command text,
which breaks quoting, variable substitution, and heredoc syntax.

## The Problem

```bash
# This FREQUENTLY fails due to *** masking breaking quotes:
source ~/.hermes/.env
curl -sL -H "Authorization: Bearer *** \  # <- quotes get corrupted
  -o model.safetensors ...
```

Symptoms:
- `bash: unexpected EOF while looking for matching \`\"'`
- `Bearer: command not found`
- `bash: -c: line 1: unexpected EOF`
- HTTP 200 with 0 bytes downloaded (auth header didn't make it)

## The Fix: Generate the Script with Python

Instead of writing the bash command inline, use Python's heredoc (`<< 'PYEND'`)
to write a script file, then execute it. Python handles the token value as a
string with no quoting ambiguity:

```python
token = open('/tmp/hftoken.txt').read().strip()
script = f'''#!/bin/bash
curl -sL -H "Authorization: Bearer {token}" \\
  -o /path/to/output \\
  "https://huggingface.co/org/model/resolve/main/file.safetensors"
'''
with open('/tmp/download.sh', 'w') as f:
    f.write(script)
```

Then run it:
```bash
chmod +x /tmp/download.sh && bash /tmp/download.sh
```

## Token Source Options

### Option A: Extract to a file first (most compatible)

```bash
# Extract token from .env to a temp file
grep ^HF_TOKEN ~/.hermes/.env | cut -d= -f2 > /tmp/hftoken.txt
chmod 600 /tmp/hftoken.txt
```

Then in Python:
```python
token = open('/tmp/hftoken.txt').read().strip()
```

### Option B: Source + export (for the outer shell)

```bash
source ~/.hermes/.env && export HF_TOKEN
python3 << 'PYEND'
import os
token = os.environ['HF_TOKEN']
# Now use token in strings with no quoting issues
PYEND
```

This works because the Python process inherits the environment variable.
The `'PYEND'` delimiter (single-quoted) prevents any bash variable expansion
inside the heredoc, so `***` masking never triggers on the Python code.

## Simpler Alternative: Auth Header File

For quick one-shard downloads where full Python script generation is
overkill, write the auth header to a file and reference it with `$(cat ...)`:

```bash
# One-time setup (read the token from .env)
grep ^HF_TOKEN ~/.hermes/.env | cut -d= -f2 > /tmp/hftoken.txt
python3 -c "
t = open('/tmp/hftoken.txt').read().strip()
open('/tmp/auth_header.txt', 'w').write(f'Authorization: Bearer *** )"

# Then use it in any command
aria2c --header="$(cat /tmp/auth_header.txt)" -x 4 ...
curl -H "$(cat /tmp/auth_header.txt)" ...
wget --header="$(cat /tmp/auth_header.txt)" ...
```

This avoids both the `***` masking issue and the need for Python code
generation. Works with curl, wget, and aria2c.

## When to Use

- Downloading HF model shards with curl/wget/aria2c where the token is
  needed in an HTTP header
- ANY bash command that needs to embed a secret in a quoted string
- Long-running background scripts that must survive Hermes process
  lifecycle (combine with `nohup` for full detachment)

For the huggingface_hub Python API (`snapshot_download`, `hf_hub_download`),
the token is read from `HF_TOKEN` environment variable automatically —
no inline embedding needed. Use `source ~/.hermes/.env && export HF_TOKEN`
before running the Python command.
