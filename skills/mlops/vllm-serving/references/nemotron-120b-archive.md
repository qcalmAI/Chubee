# Nemotron-3-Super-120B-A12B-NVFP4 Archive

> **Purpose:** Self-contained offline archive of the 120B MoE model.
> **Size:** ~75 GB raw, ~75 GB tar (safetensors don't compress further; gzip on 75 GB is too slow and risks timeout — use plain tar).
> **Origin:** `/mnt/chubee-data/super-weights/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/`
> **Archive:** `/mnt/chubee-data/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar.gz`
> **Reason for archiving:** Too large (120B params at NVFP4) to run alongside Qwen on the GB10's 128 GB unified memory.

## What's in the archive

The archive contains everything needed to run the model offline — no internet dependency:

| File | Purpose |
|---|---|
| `model-00001-of-00017.safetensors` through `model-00017-of-00017.safetensors` (17 files, ~75 GB total) | Model weights (NVFP4 quantized, 120B params, 12B active per token) |
| `config.json` | Model architecture config (layers, heads, MoE routing) |
| `generation_config.json` | Generation parameters (temperature, top-p, etc.) |
| `hf_quant_config.json` | NVFP4 quantization metadata |
| `model.safetensors.index.json` | Weight-to-shard mapping |
| `tokenizer.json` | Tokenizer vocabulary and merges |
| `tokenizer_config.json` | Tokenizer configuration |
| `special_tokens_map.json` | Special token definitions |

## Why it's too big for active use

- **120B params at NVFP4 (~4-bit) = ~60 GB weights in GPU memory**
- Qwen2.5-32B-GPTQ-Int4 simultaneously needs ~16 GB
- Ollama (vision model) needs ~5 GB
- With only 128 GB unified memory total, running both locally models simultaneously leaves ~47 GB for KV cache, OS, and Docker overhead — marginal and crash-prone

The swap-model approach (stop Qwen, start nemotron) works but takes ~8 minutes to load 75 GB of weights.

## Archival process

```bash
# Verify all 17 shards exist and are valid
cd /mnt/chubee-data/super-weights/
python3 /opt/data/skills/mlops/vllm-serving/scripts/validate-safetensors.py \
  NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/

# Archive WITHOUT compression (plain tar) — safetensors are already dense;
# gzip on 75 GB takes 10+ min and risks timeout/kill on this system.
# pigz (parallel gzip) is NOT installed.
tar -cf /mnt/chubee-data/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar \
  NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/

# Verify archive
tar -tf /mnt/chubee-data/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar | head -5
ls -lh /mnt/chubee-data/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar

# Remove live directory (frees ~75 GB of disk space)
rm -rf /mnt/chubee-data/super-weights/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/
```

## Restoration

```bash
cd /mnt/chubee-data/super-weights/
tar -xzf /mnt/chubee-data/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar.gz
# Then uncomment the vllm-nemotron service in docker-compose.yml
# and run: docker compose up -d vllm-nemotron
```

## Cleanup after archiving

After archiving, remove all references from active configuration:

1. **Remove the live weights directory** (already done above — frees disk)
2. **Strip** the nemotron vLLM service from `docker-compose.yml` completely — don't just comment out the block. Leftover commented services accumulate YAML drift from repeated patching and cause errors like `'extra_hosts' invalid additional host, missing IP: --<flag>`. The safest approach: delete the entire block.
3. **Keep the model alias** in `~/.hermes/config.yaml` — it won't hurt to have the alias point at a non-running container (selection attempt returns connection refused, not a crash)
4. **Remove any swap scripts** that reference the archived model (e.g. `swap-model.sh`)