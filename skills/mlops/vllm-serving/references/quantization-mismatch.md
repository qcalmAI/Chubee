# Quantization Mismatch Across Shards

Failure mode specific to multi-shard GPTQ/AWQ/FP4 models where shards were
downloaded via different methods (some clean wget, some corrupt aria2c) on
HF's Xet CDN.

## Symptom

vLLM loads all shards successfully (no safetensor header errors), then crashes
during engine initialization:

```
ValueError: Detected some but not all shards of model.layers.40.mlp.gate_up_proj are quantized.
All shards of fused layers to have the same precision.
```

## Root Cause

HF's Xet CDN does not tolerate multi-connection downloads (aria2c, parallel
curl, multiple simultaneous wgets). Files download to the correct byte size
but contain corrupt tensor data. When vLLM tries to fuse two sub-layers that
live in different shards, it detects one quantized (valid GPTQ) and one not
(corrupt — reads as raw fp16).

The file's safetensor **header** is valid — written early in download. Only
the **tensor payload** after the header is corrupt. `safe_open` + header
parsing passes validation, but weight loading fails.

## Diagnosis

```bash
# Shards pass header validation but fail at runtime
python3 scripts/validate-safetensors.py   # all files show OK

# Check which shards the fused layer's components live in:
python3 -c "
import json
idx = json.load(open('model.safetensors.index.json'))
layer = 'model.layers.40'
for name, shard in sorted(idx['weight_map'].items()):
    if layer in name and ('gate' in name or 'up' in name or 'down' in name):
        print(f'{name}: {shard}')
"
```

If `gate_proj` is in shard N and `up_proj` in shard N+1, and they were
downloaded with different tools, quantization data is inconsistent.

## Fix

**Do NOT restore individual shards.** Kill ALL stale processes first, then
restore ALL shards from a single trusted source:

```bash
# 1. Kill stale processes
ps aux | grep -E "model-0000|hftoken|auth_header" | grep -v grep | awk '{print $2}' | xargs -r kill -9

# 2. Delete all shards
rm -f /path/to/model-0000*-of-*.safetensors

# 3. Re-download ALL with single-connection wget (NOT aria2c, NOT parallel)
for i in 00001 00002 00003 00004 00005; do
  wget -q --header="Authorization: Bearer $(cat /tmp/hftoken.txt)" \
    -O model-${i}-of-00005.safetensors \
    "https://huggingface.co/.../resolve/main/model-${i}-of-00005.safetensors"
done

# 4. Verify all shards
# 5. Start vLLM
```

**Why deleting all first matters:** If you only replace the "bad" shard, the
remaining shards may also be corrupt (just not manifesting yet with current
layer combinations). Always restore from a complete, consistent set.

## Prevention

- **Never use aria2c for HF model downloads** (corrupts files on Xet CDN)
- **Never mix download methods** across shards of the same model
- **Always run the Kill Pattern** before any model-file operation
- **Validate shard consistency** by checking actual inference output is coherent
