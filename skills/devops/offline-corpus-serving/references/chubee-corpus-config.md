# ChubeeAcer Offline Corpus Configuration

Deployed on Acer Veriton GN100 (NVIDIA GB10 Grace Blackwell, arm64/aarch64).
Compose file: `~/chubee/stack/docker-compose.yml`

## Services

### Kiwix-serve (:8181)
- Image: ghcr.io/kiwix/kiwix-serve:latest (linux/arm64 native)
- Volume: /mnt/chubee-data/corpora:/data
- PORT env var: 8080 (start.sh wrapper)
- Status: stopped until ZIM download completes

### Filebrowser (:8182)
- Image: filebrowser/filebrowser:latest (Alpine-based)
- Volume: /mnt/chubee-data/corpora:/srv
- DB volume: /mnt/chubee-data/docker-volumes/filebrowser:/database
- Admin account: first-run randomly generated password (in logs)
- Password reset: `docker exec filebrowser filebrowser users reset admin`

## ZIM Download

### Current Download
- File: wikipedia_en_all_nopic_2026-03.zim
- Size: 48 GB
- Source: https://download.kiwix.org/zim/wikipedia/
- Dest: /mnt/chubee-data/corpora/
- Command: `wget -c --progress=dot:giga`
- Progress tracking: process(action='poll', session_id='proc_bc4b28ee2a8a')
- Typical speed: ~36 MB/s, ~20-25 min total

### Available Variants (English Wikipedia, as of June 2026)
- maxi (2026-02): 115 GB — includes images
- nopic (2026-03): 48 GB — text only (used for this deployment)
- mini (2026-03): 12 GB — curated subset

## RAG Pipeline (Future)
- Qdrant running on :6333 already in compose
- Wikipedia ZIM content to be ingested into Qdrant vector DB
- Query via LLM agent (Hermes) using RAG tools