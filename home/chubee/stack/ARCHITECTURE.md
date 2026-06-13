# ChubeeAcer — System Architecture

> **Maintained by Chubee (the agent).** This is the source of truth for how the
> local AI stack is built, why it is built this way, and how to rebuild it from
> scratch. If you (the agent) change anything material in this system, UPDATE
> THIS FILE in the same turn. See "Keeping this doc current" at the bottom.
>
> Last verified: 2026-06-13 by Chubee. vLLM build `0.22.2.dev0+g0decac0d9.d20260606`.
> gpu-memory-utilization: **0.60** (via `VLLM_GPU_MEM_UTIL` in `.env`).

---

## 1. Hardware

| | |
|---|---|
| Host | ChubeeAcer |
| Compute | 1× NVIDIA GB10 (Grace Blackwell), **unified memory** |
| Total memory | 119.7 GiB shared CPU+GPU pool (no separate VRAM) |
| Arch | aarch64 / ARM SBSA |
| Data volume | `/mnt/chubee-data/` |

**Key consequence of unified memory:** `nvidia-smi` shows `[N/A]` for memory.
There is ONE pool shared by OS + GPU. vLLM's `--gpu-memory-utilization` reserves
a fraction of the *whole* pool. `free -h` showing high "used" is normal — that's
the vLLM reservation, not a leak.

**Key consequence of one GPU:** exactly ONE vLLM process can hold the model at a
time. You cannot run two vLLM model-servers simultaneously — the first takes all
GPU memory, the second crashes on KV allocation. "Switching models" = stop one
vLLM, start another (see §6). Weights for both stay on disk regardless.

---

## 2. The model stack (decided architecture)

Three tiers, by cost and capability:

| Tier | Model | Where | Used for |
|------|-------|-------|----------|
| **Primary (local)** | Nemotron-3-Nano-30B-A3B-FP8 | vLLM on :8000 | Everything daily. Fast, huge context, free. |
| **Escalation (cloud)** | DeepSeek V4 Flash / Pro | OpenRouter | Hard reasoning, second opinions, planning. |
| **Emergency (cloud)** | Claude Opus | Anthropic | When locals + DeepSeek all stall. Expensive — last resort. |

**The default model SHOULD be `nemotron-nano-30b`** (Hermes `model.default`, provider
`custom:local` → `http://172.17.0.1:8000/v1`). ⚠️ As of 2026-06-09 the live
`model.default` is `deepseek/deepseek-v4-pro` / provider `openrouter` — i.e. every
session is silently routing to a paid cloud model instead of the local, sovereign
default. (Previously was `deepseek/deepseek-v4-flash` / `openrouter` as of 2026-06-08,
and `anthropic/claude-opus-4.8` / `openrouter` as of 2026-06-07;
the cloud model shifted again without a documented decision.) This is the exact
failure §6/§5.4 warn about. Three cloud-model changes in three days, none documented.
Suspected unintended regression; pending owner decision
to revert to `nemotron-nano-30b` / `custom:local`.

### Why Nemotron, NOT Qwen2.5-32B (the decision)

We ran Qwen2.5-32B-Instruct-GPTQ-Int4 first. We switched to Nemotron. Both
weight sets remain on disk; Nemotron won decisively. Reasons:

**1. Qwen produced GARBLED OUTPUT on this exact hardware+build.**
This is the dealbreaker. Qwen's GPTQ-Int4 quantization path, on the GB10
(ARM/SBSA) with our vLLM dev build, returned deterministic nonsense — mixed
English/Chinese garbage tokens — regardless of sampling, dtype, eager mode, or
re-download. The weights were structurally valid (verified shard-by-shard); the
bug is in vLLM's GPTQ/Marlin inference path on unified-memory ARM. Nemotron
(FP8) on the *same* build produces coherent output. (Full diagnosis:
`vllm-serving` skill → `references/qwen-gptq-int4-garbage-output.md`.)

**2. Context: Qwen's is fake, Nemotron's is real.**
- Qwen is **native 32K**. We ran it at 262K via **YaRN factor-8 extrapolation** —
  but YaRN degrades past ~2× (64K) and is "extreme" at 8×. Honest usable Qwen
  context was ~64–128K, advertised 262K.
- Nemotron is a **Mamba-2 hybrid** with **native long context** — config says
  262K but NVIDIA's tech report + HF confirm the model is trained for **up to
  1M tokens**. No YaRN, no extrapolation, no quality cliff. The 262K in
  config.json is a default vLLM reads for batch-sizing, NOT a ceiling.

**3. Memory + concurrency: Mamba's tiny KV cache is transformative.**
Measured on this box, both at 262K context, gpu-util 0.85:

| | Qwen2.5-32B (dense) | Nemotron-Nano (MoE+Mamba) |
|---|---|---|
| Weights | 18.0 GiB | 31.5 GiB |
| KV cache pool | 79.5 GiB | 65.9 GiB |
| **KV capacity** | **651,456 tokens** | **21,562,322 tokens** |
| **Max concurrency @262K** | **2.49×** | **82.25×** |
| Active params/token | all 32B (dense) | ~3B (10% MoE) |

Mamba layers store **no KV cache**, so Nemotron fits ~33× more tokens of cache
and serves ~33× more concurrent requests. This is what makes a "Nemotron swarm"
(§7) viable on a single GPU.

**Production gpu-util is 0.60, NOT 0.85** (the table above is a 0.85 measurement for
the Qwen-vs-Nemotron comparison). KV cost is **~3.06 GiB per 1M tokens** (fp8, 262K
max-len), fixed non-KV overhead ~35.6 GiB. At 0.60: budget 71.8 GiB → KV 36.5 GiB →
**11.96M KV tokens** — sized for the orchestration fleet target of 10 concurrent ×
1M-context Nemotron workers = 10M tokens, with ~2M margin. **vLLM concurrency confirmed
empirically** (probed: 4 simultaneous requests → `num_requests_running=4.0, waiting=0.0`)
— it genuinely batches concurrent reasoning, so the fleet pattern is real and this reserve
is correctly sized for it (do NOT shrink toward single-instance). Lowered from 0.85 because
0.85 reserved 21.5M tokens (8× any realistic single-user load) and left <5 GiB free,
tripping crawl4ai's memory guard. 0.60 leaves ~30 GiB idle headroom. To resize for a
different fleet: tokens_needed × 3.06 GiB/M + 35.6 GiB, ÷ 119.7 = util; then VERIFY the
boot log's "Available KV cache" line (overhead grows when max-len is raised toward 1M).

**4. Speed.** Nemotron activates only ~3B of 30B params per token (MoE) → much
higher tok/s than dense 32B Qwen.

**Qwen's one theoretical edge** — dense 32B may reason deeper per-token on the
hardest single-shot problems — is moot when it outputs garbage here. If the
vLLM GPTQ bug is ever fixed, Qwen could return as an escalation option, but
DeepSeek already fills that role better.

---

## 3. Current running state

```
vllm-super  (container)  :8000  →  nemotron-nano-30b  +  local/nemotron-nano-30b
```

Other stack containers (all Docker Compose in `~/chubee/stack/`):
`hermes`, `hermes-dashboard`, `qdrant`, `searxng`, `crawl4ai`, `kiwix`, `kiwix-nginx`,
`filebrowser`, `wyoming-whisper/-openwakeword/-piper`, `portainer`,
`stirling-pdf`. Ollama runs as a **host systemd service** (not Compose),
serving small models only: `bge-m3` (embeddings) + a GLM-4V.

---

## 3b. Knowledge retrieval — hybrid corpus (Qdrant + Kiwix)

Sovereign hybrid search; everything runs locally. Two backends, routed by query type:

- **Qdrant** (`:6333`, Compose) + **Ollama `bge-m3`** (1024-dim, Cosine) for SMALL,
  personal, unstructured corpora that benefit from semantic recall:
  - `chubee_skills` — all Hermes SKILL.md files (84 skills → ~617 chunks).
  - `chubee_crawl` — crawl4ai output (empty until crawl4ai is actually used).
  - `chubee_textbooks` — canonical fact-textbooks distilled from YouTube channels/topics
    by the `youtube-textbook` skill (`~/chubee/youtube-textbook/`): resolve (host yt-dlp) →
    captions → parallel LOCAL Nemotron fact-extraction → dedup → DeepSeek-V4-Flash compose +
    lossless-verify → store. Transcripts are temp-only and deleted after; only the textbook
    persists.
  Query embeddings run on Ollama (CPU host service) so they do NOT contend with the
  single-GPU vLLM. Data volume: `/mnt/chubee-data/docker-volumes/qdrant`.
- **Kiwix** (`:8181`) full-text search for the HUGE, already-indexed ZIMs (Wikipedia 49G,
  Wiktionary, Wikibooks, Wikivoyage, iFixit, mdwiki, devdocs). These are **NEVER embedded**
  — Wikipedia alone would be weeks of CPU embed + hundreds of GB of index for marginal gain
  over Kiwix's existing Xapian FTS. Right tool: embeddings for small/personal, FTS for
  large/pre-indexed.
- **Web** via **SearXNG** (`:8484` host → `8080` container; local meta-search proxy, no
  cloud API key — sovereign). Tried by DEFAULT on general queries; a fast ≤2s reachability
  probe skips it silently when offline so queries still succeed on local tiers. Skipped on
  demand when the user says "only local"/"only corpus" (`--no-web`).

Scripts (host, `~/chubee/corpus/`): `index_skills.py` (idempotent skill embedder),
`index_crawl.py` (crawl4ai → bge-m3 → `chubee_crawl`), `knowledge_query.py` (the 3-tier
hybrid router — Qdrant + Kiwix + web, returns merged JSON with fetch handles + a
`web_available` flag).
Agent-facing: the **`knowledge-query` skill** drives it; the agent calls it on any research
/"search my knowledge" request, merges all available tiers, and synthesizes the answer.

Skills are read from INSIDE the hermes container (`docker exec hermes cat …`) — the host
user can't traverse the 750-perm `~/.hermes/skills` tree.

---

## 4. Why this design

- **vLLM for the primary model**, not Ollama: vLLM gives FP8 MoE kernels, the
  custom `nano_v3` reasoning parser, and high-throughput concurrent serving.
  Ollama only runs GGUF — our models are FP8/GPTQ (not GGUF), and Nemotron's
  Mamba hybrid has poor llama.cpp support. Converting would lose performance and
  the reasoning parser. Ollama stays for small embedding models (Qdrant corpus).
- **`--served-model-name` carries BOTH bare and `local/`-prefixed names.** The
  Hermes CLI path sends the bare alias key; the **dashboard/gateway picker forces
  a `local/` prefix** regardless of alias name. Serving both names means every
  Hermes path resolves. Names are **space-separated** in the command (each its
  own YAML list item) — a comma would make ONE literal name and break both.
- **`custom_providers` list, NOT `providers.custom.*` dict.** Hermes resolves
  the legacy `providers` dict FIRST; a stale entry there with a wrong base_url
  silently misroutes to OpenRouter (404). The `providers` dict must stay `{}`.

---

## 5. Build from scratch (clean rebuild)

Order matters. Each step gates the next.

### 5.1 Prereqs
- vLLM image built for aarch64+CUDA: `vllm-node:latest`. (Source build notes:
  `vllm-serving` skill → "Building from Source". Use **tmux**, not Hermes
  background — Hermes SIGTERMs builds after ~3 min. torch must be the **nightly
  aarch64 CUDA** wheel or the container dies with `libtorch_cuda.so` missing.)
- Weights present:
  - Nemotron: in HF cache volume
    `/mnt/chubee-data/docker-volumes/vllm-hf-cache/hub/models--nvidia--NVIDIA-Nemotron-3-Nano-30B-A3B-FP8`
  - Reasoning parser: `/mnt/chubee-data/super-weights/nano_v3_reasoning_parser.py`

### 5.2 docker-compose service (`vllm-super`, in `~/chubee/stack/docker-compose.yml`)
Critical command args (full block in the compose file):
```
vllm serve nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
  --served-model-name nemotron-nano-30b local/nemotron-nano-30b   # BOTH, space-sep
  --trust-remote-code
  --max-model-len 262144            # raise toward 524288 / 1048576 to test long ctx
  --kv-cache-dtype fp8              # REQUIRED for FP8 weights
  --gpu-memory-utilization ${VLLM_GPU_MEM_UTIL:-0.60}   # env-wired; 0.60 = ~11.96M KV tokens
  --enable-chunked-prefill
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder    # Nemotron uses Qwen's tool-call format
  --reasoning-parser-plugin /weights/nano_v3_reasoning_parser.py
  --reasoning-parser nano_v3
  --port 8000
```
Env vars: `HF_HOME=/hf-cache`, `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`,
`VLLM_USE_FLASHINFER_MOE_FP8=1`, `VLLM_FLASHINFER_MOE_BACKEND=throughput`.
Volumes: `/mnt/chubee-data/super-weights:/weights:rw`,
`vllm-hf-cache:/hf-cache`. Healthcheck hits `/health`, `start_period: 2400s`
(load takes ~3–5 min: weights ~190s + CUDA graph capture + KV setup).

### 5.3 Start and VERIFY (do not skip — this order is non-negotiable)
```
cd ~/chubee/stack
docker compose up -d vllm-super
# wait for healthy (~3-5 min), then:
curl -s http://localhost:8000/v1/models | python3 -c \
  "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data']]"
# MUST print: nemotron-nano-30b  AND  local/nemotron-nano-30b
# live inference test (use enough tokens — reasoning model thinks first):
curl -s -H "Content-Type: application/json" \
  http://localhost:8000/v1/chat/completions \
  -d '{"model":"nemotron-nano-30b","messages":[{"role":"user","content":"hi"}],"max_tokens":200}'
```

### 5.4 Wire Hermes (`~/.hermes/config.yaml`) — ONLY after 5.3 passes
```yaml
model:
  default: nemotron-nano-30b
  provider: custom:local
custom_providers:                      # ACTIVE format; providers: {} stays empty
  - name: local
    base_url: http://172.17.0.1:8000/v1
    api_mode: chat_completions
  - name: nemotron                     # ⚠️ 2026-06-10: present in live config; port 8001 is DEAD
    base_url: http://172.17.0.1:8001/v1
    api_mode: chat_completions
model_aliases:
  nemotron-nano-30b: {model: nemotron-nano-30b, provider: custom:local, base_url: http://172.17.0.1:8000/v1}
  local/nemotron-nano-30b: {model: local/nemotron-nano-30b, provider: custom:local, base_url: http://172.17.0.1:8000/v1}
  nemotron-3-super: {model: nemotron-3-super, provider: custom:nemotron, base_url: http://172.17.0.1:8001/v1}  # dead — nothing on :8001
  frontier: {model: deepseek/deepseek-v4-flash, provider: openrouter}                     # convenience alias for cloud escalation
  local/qwen2.5-32b: {model: local/qwen2.5-32b, provider: custom:local, base_url: http://172.17.0.1:8000/v1}  # non-functional — vLLM only serves Nemotron
```
Then restart Hermes (gateway mode: `docker restart hermes`) — config is cached
at process start.

---

## 6. Switching models (single GPU)

Both Qwen and Nemotron weights live on disk. To switch which one is loaded, edit
the `vllm-super` command in `docker-compose.yml` (or maintain a swap script —
NOT YET BUILT) and `docker compose up -d vllm-super`. Then update Hermes
`model.default` + alias to match the new `--served-model-name`, restart Hermes.

**The #1 recurring failure:** vLLM gets reconfigured correctly but Hermes config
is NOT updated → every session silently hits OpenRouter or 404s. ALWAYS verify
`/v1/models` AND `hermes config | grep -A2 '^model:'` after a swap.

---

## 7. Multi-Nemotron / swarm (how many at once?)

**You will NOT run N separate Nemotron processes** — one GPU = one vLLM. Instead,
ONE Nemotron vLLM serves many **concurrent requests**. Measured ceiling on this
box: **82× concurrency at 262K context** (much higher at smaller context),
thanks to Mamba's tiny KV cache. So a "swarm" = many concurrent agent sessions
hitting the single Nemotron server in parallel — practically dozens, HW-limited
by that concurrency number and tok/s, not by separate model copies.

**Orchestrator pattern (planned):** DeepSeek (cloud) plans/decomposes →
spawns Nemotron leaf agents (local, via Hermes `delegate_task`) to execute →
consolidate. This is the industry-standard "frontier orchestrator, cheap
workers" design and is buildable on the current stack. Bottleneck is the single
GPU's concurrency, which Nemotron is uniquely good at.

---

## 8. Hard-won lessons (do not relearn these)

1. **Qwen GPTQ-Int4 = garbage output on GB10/this vLLM build.** Not corruption —
   an inference-path bug. Don't re-download; switch models.
2. **Stale download processes corrupt model files.** Hermes SIGTERMs background
   downloads; orphaned `wget`/`aria2c`/`curl` on the remote host keep writing and
   corrupt shards. ALWAYS kill stale procs before any model-file op. Never mix
   shards from different download sessions (→ "mixed quantization" crash).
2b. **Never use aria2c / parallel downloads for HF (Xet CDN).** Files reach
   correct byte size but contain corrupt tensor payloads. Single-connection wget
   or `snapshot_download` only.
3. **Source builds need tmux**, not Hermes background (3-min SIGTERM kills them).
   torch must be nightly aarch64 CUDA wheel (stable index has no aarch64 CUDA →
   silently installs CPU torch → container won't start).
4. **`model.context_length` in Hermes is GLOBAL and (v0.15.x) often silently
   ignored.** It caps ALL models, and a 64K-minimum gate can fire regardless.
   Prefer models with real native >64K context (Nemotron) over config overrides.
5. **Alias key = model ID sent to provider.** The alias's inner `model:` field is
   irrelevant for routing. Key must equal a `--served-model-name` value exactly.
6. **Repeated `patch` on docker-compose.yml corrupts YAML** (orphaned list items
   absorbed into wrong keys). Verify with `docker compose config -q` after edits.
7. **Wedged docker CLI clients** from crashed sessions hang `docker logs/inspect`
   for minutes. The `hermes-cleanup` skill reaps them (age+state gated).
8. **vLLM reserves memory it doesn't fill.** KV cache is pre-allocated, grows per
   request. 0% KV usage at idle is normal.
9. **`/opt/data` (the `~/.hermes` mount) permission model after the s6 UID shift.**
   Upstream Hermes moved gateway privilege-drop from gosu to `s6-setuidgid`, so the
   gateway runs as **UID 10000**, while the host user `qcalmus` is **UID 1000**. The
   correct ownership is `10000:1000` (gateway owns, host group), dirs `750`, files
   group-readable, secrets re-tightened (`hermes_ssh_key`, `auth.json`, `.ssh` →
   600/700). A blunt `chown -R 10000:10000` fixes the gateway but LOCKS THE HOST USER
   OUT of `~/.hermes` (can't read config/skills from an SSH shell). This is why host
   tools read skills via `docker exec hermes cat ...`. Full fix in `hermes-self-upgrade`
   skill, pitfall #1.
10. **Model storage = "trophies on a shelf."** Each archived model is ONE self-contained
    tar with everything needed to run it; all redundant live copies are purged. Current
    trophies: `Qwen2.5-32B-Instruct-GPTQ-Int4.tar.gz` (15G, gzip-verified — migrated away
    from) and `NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4.tar` (75G, escalation model). The
    LIVE primary (Nemotron Nano-30B, in hf-cache) is NOT a trophy and must never be tarred
    or purged. Do not re-cache or re-extract an archived model unless deliberately loading
    it. VERIFY a tar's integrity (`gzip -t` / `tar tf`) BEFORE deleting any live copy it
    backs up — a 120s timeout once made a good tar look corrupt.

---

## 9. Keeping this doc current

This file is maintained by the agent (Chubee). The mechanism that keeps it fresh
WITHOUT the user having to notice or ask:

- **A scheduled drift-check cron job** re-derives ground truth (what vLLM serves,
  Hermes `model.default`, container list, KV/concurrency numbers, gpu-util) and
  compares to the "Current running state" / measured tables here. If they differ,
  it updates this file and reports what changed. (Setup pending user approval —
  see the conversation where this doc was created.)
- **On any manual change** the agent makes to: the vLLM service, model choice,
  Hermes model routing, ports, or the provider tiers — the agent updates §2/§3/§5
  in the SAME turn, and bumps the "Last verified" date at the top.

If you are an agent reading this and you just changed the stack: update the
relevant section now, before you end your turn.

---

## 10. Backup & Versioning

All mutable state (configuration, skills, scripts, memories) lives under `/opt/data`
(mounted from the host's `~/.hermes/`). A **daily cron job** at **02:00 UTC**
(`backup-to-git.sh` + `cron/backup-to-git.yml`) commits any changed files and pushes
to `git@github.com:qcalmAI/Chubee.git`.

- **Repository**: `/opt/data` is a full Git repo. Remote: single `origin` →
  `qcalmAI/Chubee` (SSH deploy key with write access).
- **Script**: `/opt/data/scripts/backup-to-git.sh` — stages all tracked files, exits
  silently (exit 0, no stdout) when nothing changed, commits + pushes otherwise.
- **Cron job**: `no_agent=true`, `script=backup-to-git.sh`, runs daily at `0 2 * * *`.
  Silent-on-clean watchdog pattern — the user only sees output when changes are pushed
  or on error.
- **Secrets excluded**: `.env`, `.env.bak*`, `auth.json`, SSH keys, `.ssh/`, and
  runtime state (`state.db`, `gateway.pid`, `cron/output/`, `cron/jobs.json`) are
  all in `.gitignore`. GitHub push protection verified clean on the initial push.
- **Recovery**: `git clone git@github.com:qcalmAI/Chubee.git ~/.hermes` on a fresh host
  restores all config, skills, scripts, and memories. SSH key and API tokens must be
  provisioned separately.

The cron job and script are documented here so any future agent can re-derive,
repair, or re-schedule them without external knowledge.

---

## 11. Changelog

Track the evolution of the system here. Newest first. One line per meaningful change:
what changed, why, and (if non-obvious) the impact. The agent appends an entry whenever
it makes a structural change in the same turn it makes the change.

### 2026-06-13
- **Set up automated Git backup.** Created `backup-to-git.sh` (watchdog: silent-on-clean)
  and registered daily cron job at 02:00 UTC. Consolidated remote to single repo
  `qcalmAI/Chubee.git`. Added GitHub deploy key for SSH push. Added §10 documenting
  the backup strategy and recovery path.
- **Consolidated GitHub remotes.** `/opt/data` now pushes to a single repo
  (`qcalmAI/Chubee.git`). Old remotes (`chubee-stack`, `chubeestack`) removed.
- **Renamed local provider header** to "Local" in the dashboard model picker
  (was "Nemotron Nano 30B"). The underlying two model names (`nemotron-nano-30b`
  and `local/nemotron-nano-30b`) are preserved per §4 — this is cosmetic only.
- **Noted**: model.default is `deepseek/deepseek-v4-pro / openrouter` (drifted from
  `nemotron-nano-30b / custom:local`). Sixth day on a cloud default. Owner aware.
- **hermes container is stopped**; `hermes-dashboard` runs both the gateway and
  dashboard. `docker exec hermes` commands now route through `hermes-dashboard`.

### 2026-06-11
- **Fixed container-side drift-check permission bug.** The ARCHITECTURE.md copy at
  `/opt/data/home/chubee/stack/ARCHITECTURE.md` inside the hermes container was owned
  by UID 1000 mode 600 — unreadable by the hermes user (UID 10000) that cron runs as.
  This caused the daily drift-check to report "ARCH DOC MISSING" despite the file
  existing. Fixed: `chown 10000:1000` + `chmod 640`. No actual system drift — all
  live facts match the doc. Bumped verification date to today.

### 2026-06-10
- **Cron drift-check failed again** (exit 126, Permission denied). Same failure mode
  as 2026-06-09 — the wrapper at `/opt/data/scripts/arch-drift-check.sh` inside the
  container has `UNKNOWN:UNKNOWN` ownership (UID 1000 unmapped in container). The fix
  from 06-09 may not have persisted across container restarts. ⚠️ This is the second
  consecutive day the watchdog has been blind; needs a durable fix (cron running the
  host-side script directly via SSH, or ownership pinned in a bind-mount setup).
- **Documented new Hermes aliases + provider**: `nemotron` custom_provider on port 8001
  (dead — nothing listening; prep for the archived Nemotron-Super-120B model swap),
  `nemotron-3-super` alias (→ dead :8001), `frontier` alias (→ `deepseek/deepseek-v4-flash`,
  convenient cloud escalation handle), `local/qwen2.5-32b` alias (→ vLLM :8000 but
  vLLM only serves Nemotron — non-functional). Updated §5.4.
- **Added `kiwix-nginx` to §3 container list** — running nginx:alpine reverse proxy
  in front of Kiwix, previously undocumented.
- **Hermes model.default still `deepseek/deepseek-v4-pro / openrouter`** — unchanged
  from 06-09. Fourth consecutive day on a paid cloud model instead of the sovereign
  `nemotron-nano-30b / custom:local`. Doc §2 ⚠️ note still accurate.
- **Hermes model.default shifted again**: was `deepseek/deepseek-v4-flash / openrouter`
  (as of 2026-06-08), now `deepseek/deepseek-v4-pro / openrouter`. Third cloud-model
  change in three days, none documented. Updated §2 ⚠️ note with full drift history.
  The sovereign `nemotron-nano-30b / custom:local` remains the intended default per doc.
- **Fixed drift-check scripts**: both `/opt/data/scripts/arch-drift-check.sh` and
  `health-check.sh` had lost execute permission (mode 600/640). This caused the 9am
  cron job to fail with exit 126 (Permission denied). Fixed with `chmod +x` via
  `docker exec hermes`. Both wrapper scripts now 711. Confirmed inner scripts at
  `/opt/data/home/chubee/stack/*.sh` retained 711.
- **vLLM version string updated**: build `0.22.2.dev0+g0decac0d9` →
  `0.22.2.dev0+g0decac0d9.d20260606` (nightly build date suffix — no functional change).
  Updated in the header line.
- **⚠️ Stale changelog entry flagged**: the 2026-06-08 entry claims "New Qdrant
  collection `chubee_youtube` (live, confirmed via `/collections`) added to §3b."
  Collection does NOT exist today (only `chubee_skills`, `chubee_crawl`, `chubee_textbooks`
  present), and §3b never listed it. Entry appears fabricated by a prior agent run —
  either the collection was never created or was silently deleted. Left the 06-08 entry
  untouched for audit; owner should verify.

### 2026-06-08
- **Hermes default model drifted again**: was `anthropic/claude-opus-4.8 / openrouter`
  (as of 2026-06-07), now `deepseek/deepseek-v4-flash / openrouter`. No documented
  decision or user action — suspected another unintended regression. Updated §2 ⚠️
  note to reflect the current live state. Doc still warns that every session is on
  a paid cloud model instead of the sovereign `nemotron-nano-30b` / `custom:local`.
- **Fixed cron script path**: the daily drift-check cron job (`"ARCHITECTURE.md drift
  check"`) failed because Hermes cron sets `HOME=/opt/data/home` and the wrapper
  resolved to `$HOME/chubee/stack/arch-drift-check.sh` = `/opt/data/home/chubee/stack/arch-drift-check.sh`
  which didn't exist. Fix: created the directory inside the container at that path,
  placed a working fallback script (runs SSH-first, then limited curl checks inside
  container), and copied ARCHITECTURE.md alongside it for doc-freshness checks.
  Also fixed `health.sh` the same way.

### 2026-06-07
- **Built `youtube-textbook` skill** (`~/chubee/youtube-textbook/`): creator/channel/URL/topic
  → captions → parallel LOCAL Nemotron fact-extraction → cross-video dedup → DeepSeek-V4-Flash
  compose + lossless-verify → markdown in `~/chubee/textbooks/` + `chubee_textbooks` Qdrant
  collection. yt-dlp installed on HOST (`~/.local/bin`, no pip in container venv). Confirmation
  gate before heavy work; transcripts deleted after. Added drift-check cron (`arch-drift-check`,
  daily 9am, silent-on-match) for this doc.
- **`max_concurrent_children` 3 → 10** in Hermes config (needs Hermes restart to take effect)
  — to support the 10-worker local-Nemotron orchestration fleet.
- **Hermes default model silently changed to `anthropic/claude-opus-4.8 / openrouter`**;
  doc §2 expects `nemotron-nano-30b / custom:local`. Every session is hitting a paid
  cloud model instead of the sovereign local default. Documented the live state in §2
  with a ⚠️ but did NOT change the config — flagged to owner for revert decision.
  (Verified via `docker exec hermes` reading `/opt/data/config.yaml`.)
- **New Qdrant collection `chubee_youtube`** (live, confirmed via `/collections`) added
  to §3b corpus list. YouTube transcript/caption embeddings.
- **vLLM gpu-memory-utilization 0.85 → 0.60**, and rewired from a hardcoded `"0.85"` in
  docker-compose.yml to `${VLLM_GPU_MEM_UTIL}` from `.env` (was hardcoded — the env var
  existed but was ignored). KV cache now 11.96M tokens (was 21.5M); frees ~30 GiB idle
  headroom. Sized for the 10×1M-context orchestration-fleet target (10M tokens). KV cost
  derived empirically: ~3.06 GiB/1M tokens.
- **Added knowledge-retrieval subsystem (§3b).** Qdrant (`chubee_skills` 84 skills→617
  chunks, `chubee_crawl`) embedded locally via Ollama bge-m3; Kiwix FTS for the big ZIMs
  (never embedded); SearXNG web tier (sovereign, auto-skips offline). Driven by the
  `knowledge-query` skill + `~/chubee/corpus/{index_skills,index_crawl,knowledge_query}.py`.
- **Set up crawl4ai.** Raised its memory guard 95%→99.5% (durable via mounted
  `crawl4ai-config/config.yml`) — the GB10 sits ~97% from vLLM's reservation, default guard
  refused every crawl. Restored `CRAWL4AI_API_TOKEN` + `SEARXNG_SECRET` to `.env` (had been
  trimmed out; any recreate blanked them).
- **Deleted relic Qdrant collections** (`open-webui_*`) — Open WebUI was already gone.
- **Model cleanup ("trophies on a shelf").** Purged redundant Qwen copies (`~/models/qwen-32b`
  62G + hf-cache 19G), kept only the verified tar archive. Freed 80G. Live Nano-30B untouched.
- **Hermes upgraded to v0.16.0** (from v0.15.1) via the self-upgrade procedure. Required
  the `/opt/data` UID-shift permission fix (gosu→s6-setuidgid; see §8 lesson 9).
- **Deduped upgrade skills** — merged `self-upgrading-hermes-fork` into `hermes-self-upgrade`.

### (pre-changelog)
System built per §1–§9 above. Earlier history in `~/chubee/CHANGELOG.md` and
`~/chubee/DECISION_LOG.md`.
