---
name: offline-corpus-serving
description: "Set up Kiwix (ZIM server) and Filebrowser for offline content serving via Docker Compose. Covers ZIM download strategy, compose config, working-endpoint cheat sheet, search relevance (suggest-API title-index), and nginx dark-theme injection. Use when deploying offline knowledge bases, adding new ZIMs, or troubleshooting Kiwix search."
version: 1.1.0
author: Chubee
license: MIT
metadata:
  hermes:
    tags: [kiwix, zim, wikipedia, filebrowser, offline, corpus, docker, compose]
    related_skills: [docker-compose-services]
---

# Offline Corpus Serving

Serve offline knowledge bases (Wikipedia, Wiktionary, Stack Exchange, etc.) via
Kiwix-serve + Filebrowser, managed via Docker Compose on ChubeeAcer.

## Architecture

```
Corpus data (/mnt/chubee-data/corpora/)
  │
  ├── Kiwix-serve (:8180 internal)    Filebrowser (:8182)
  │     HTTP ZIM reader                 Web file manager
  │
  └── nginx reverse proxy (:8181)
        - injects dark CSS via sub_filter
        - healthcheck uses 127.0.0.1 (Alpine IPv6 quirk)
```

## Docker Compose Configuration

### Kiwix-serve — Port 8181 (via nginx proxy)

Image moved from Docker Hub to **ghcr.io**. Use `ghcr.io/kiwix/kiwix-serve`,
NOT `kiwix/kiwix-serve`.

**Option A — Direct ZIM path (simpler):**
```yaml
kiwix:
  image: ghcr.io/kiwix/kiwix-serve:latest
  container_name: kiwix
  restart: unless-stopped
  ports: ["8180:8080"]
  volumes: ["/mnt/chubee-data/corpora:/data"]
  command: ["/data/wikipedia_en_all_nopic_2026-03.zim"]
  environment: [PORT=8080]
  healthcheck:
    test: ["CMD-SHELL", "wget -q http://127.0.0.1:8080 -O /dev/null"]
    interval: 30s; timeout: 10s; retries: 3; start_period: 30s
```

**Option B — Library XML (use when direct path fails):**

Some kiwix-serve versions reject direct ZIM paths. Create `library.xml` from
the HOST side (container is uid 1001, can't write to `/`):

```bash
cat > /mnt/chubee-data/corpora/library.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<library version="20110515"></library>
EOF
docker exec kiwix sh -c 'kiwix-manage /data/library.xml add /data/<file>.zim'
docker exec kiwix sh -c 'kiwix-manage /data/library.xml show'
```

Then in compose: `command: ["--library", "/data/library.xml"]`.
For full debug chain, see `references/kiwix-library-xml-workaround.md`.

**Key points:**
- Image uses `$PORT` env var, NOT `--port` CLI flag — passing `--port=8080`
  gets interpreted as a ZIM filename.
- Container is Alpine: no `bash`, no `curl`. Use `wget` for healthchecks.
- **127.0.0.1 not localhost** — Alpine resolves `localhost` to `::1` (IPv6)
  while services bind IPv4 only.
- **Do not start Kiwix before ZIM download completes.** Partial ZIMs cause
  `Unable to add the ZIM file` restart loops.

### Filebrowser — Port 8182

```yaml
filebrowser:
  image: filebrowser/filebrowser:latest
  container_name: filebrowser
  restart: unless-stopped
  ports: ["8182:80"]
  volumes:
    - /mnt/chubee-data/corpora:/srv
    - /mnt/chubee-data/docker-volumes/filebrowser:/database
  command: --address=0.0.0.0 --port=80 --root=/srv --database=/database/filebrowser.db
  healthcheck:
    test: ["CMD-SHELL", "wget -q http://127.0.0.1:80 -O /dev/null"]
```

- First run creates `admin` user with random password (printed to logs).
- Database persists in volume — password survives recreation.
- To reset password: `docker exec filebrowser filebrowser users reset admin`
- Must set `--address=0.0.0.0` (default is 127.0.0.1 — unreachable from host).

### nginx Dark Theme Proxy

Kiwix has no `--customCSS` flag. nginx injects dark CSS via `sub_filter`:

```nginx
server {
    listen 8080;
    location / {
        proxy_pass http://kiwix:8080;
        sub_filter '</head>' '<style>
  body { background: #0f1115 !important; color: #e6e6e6 !important; }
  a { color: #4c8bf5 !important; }
  input, select, button { background: #181b22 !important; color: #e6e6e6 !important; }
  table, tr, td, th { background: #181b22 !important; color: #e6e6e6 !important; }
</style></head>';
        sub_filter_once on;
        sub_filter_types text/html;
    }
}
```

Compose: internal Kiwix on 8180, nginx on 8181 with config mounted.
Full config: `references/kiwix-nginx-css-injection.md`.

## Working Endpoint Cheat Sheet (kiwix-tools 3.8.2)

Two identifiers, NOT interchangeable:
- **Catalog `<name>`** (from library.xml, e.g. `wikipedia_en_all`)
- **Content path** (ZIM filename minus `.zim`, e.g. `wikipedia_en_all_nopic_2026-03`)

```bash
# What does kiwix serve? (get content paths)
curl -s http://localhost:8181/catalog/v2/entries | grep -E '<name>|href="/content'

# Fulltext search — these WORK:
curl -s 'http://localhost:8181/search?pattern=Einstein&pageLength=2'
curl -s 'http://localhost:8181/search?books.filter.name=wikipedia_en_all&pattern=Einstein'
curl -s 'http://localhost:8181/search?content=wikipedia_en_all_nopic_2026-03&pattern=Einstein'

# Title-index suggest (BEST for relevance — matches article titles):
curl -s 'http://localhost:8181/suggest?content=wikipedia_en_all_nopic_2026-03&term=Einst'

# This FAILS — books.name= is the wrong param:
curl -s 'http://localhost:8181/search?books.name=wikipedia_en_all&pattern=Einstein'
```

A working search returns `Results <b>1-2</b> of <b>N</b>`.

## Search Relevance

Kiwix fulltext is **Xapian term-frequency ranked** with NO server-side relevance
knobs. Consequence: list/index pages that repeat a word hundreds of times outrank
the main article (e.g. "List of Major League Baseball players…" outranks "Baseball").

**Primary fix — suggest-API title-index search (deployed in `welcome.html`):**
The welcome page bypasses `/search` entirely. It fetches `/suggest` by article
title, renders results sorted by relevance, and promotes exact matches to position 1.
Full implementation: `references/kiwix-suggest-api-html-entities.md` and
`references/kiwix-multi-book-category-search.md`.

**The suggest API `path` field is the ONLY reliable way to build article URLs.**
Different ZIM types use radically different path structures:

| ZIM Type | Example `path` | Pattern |
|---|---|---|
| Wikipedia | `Superman` | Article title (simple) |
| Wiktionary | `boat` | Article title |
| iFixit | `Device/Chevrolet_Corvair` | `Device/` or `Guide/` + title |
| Stack Exchange | `questions/1416005/python-virtualenv-python-3` | `questions/ID/slug` |
| LibreTexts | `index/page_14493` | `index/page_NNNNN` |

**DO NOT construct URLs from `value`.** Use `path` directly. `value` only works
for Wikipedia/Wiktionary — everything else returns 404.

## Diagnosis Order (Kiwix search broken)

1. **Confirm server works** via the bare and `content=` endpoint curls above.
2. **If server works but landing-page search box returns nothing**, the cause is
   the **empty-language-filter bug**: kiwix skin auto-detect emits
   `books.filter.lang=` with an EMPTY value, which kiwix-serve rejects.
   Reproduce: `curl -s 'http://<host>:8181/search?books.filter.lang=&pattern=kansas'`
   → "Invalid request". Fix: bookmark an explicit-lang URL:
   `http://<host>:8181/search?books.filter.lang=eng&pattern=<query>`.
3. **For programmatic access**, always use `content=<zim-filename-no-ext>`.
4. **Never mutate a working service while diagnosing.** Prove the server is
   actually broken via read-only probes before editing config or deleting files.
   See `references/kiwix-search-troubleshooting.md`.

## `--customIndex` — cached at startup

kiwix-serve reads `--customIndex` HTML once at process start. Editing `welcome.html`
on disk does NOT change served content until `docker compose restart kiwix`. Also:
any custom HTML must be `chmod 644` — perms owner-only (600) make it unreadable by
the container (uid 1001).

## Downloading ZIM Files

**Always detach long downloads via `tmux` or `setsid`** — Hermes' background
watcher SIGTERMs tracked jobs after ~300s. Full bulletproof pattern:
`references/bulletproof-downloads.md`.

Quick reference:
```bash
tmux new-session -d -s dl 'cd /mnt/chubee-data/corpora && \
  wget -c --progress=dot:giga https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic_2026-03.zim \
  > /tmp/zim_dl.log 2>&1'
tail -5 /tmp/zim_dl.log
```

Typical throughput: ~36 MB/s (single stream). Parallel streams drop to ~15-25 MB/s
each. Sequentialize large downloads.

**Do not start Kiwix until download finishes.** Verify with `ls -lh`.

## Actual ZIM Sizes (measured mid-2026)

| Collection | Expected | Actual | Notes |
|---|---|---|---|
| Wikipedia nopic | ~48 GB | ~48 GB | Text-only, best for LLM RAG |
| Project Gutenberg | ~65 GB | **221 GB** | Biggest surprise |
| Stack Overflow | ~20 GB | **80 GB** | Frozen 2023-11 |
| LibreTexts (13 subjects) | ~20 GB | ~16 GB | Closest to estimate |

Full per-file breakdown: `references/zim-file-sizes.md`.

## Common Pitfalls

1. **Kiwix image on Docker Hub is gone.** Use `ghcr.io/kiwix/kiwix-serve`.
2. **Passing `--port` as CLI arg** gets interpreted as ZIM filename. Use `$PORT` env var.
3. **Starting Kiwix before ZIM download completes** causes restart loops.
4. **Alpine `localhost` → IPv6** breaks healthchecks. Use `127.0.0.1`.
5. **Filebrowser binds 127.0.0.1 by default.** Set `--address=0.0.0.0`.
6. **Library XML must be created from host side** (uid 1001 can't write to `/`).
7. **`--customIndex` is cached at startup** — restart after edits.
8. **`books.name=` is the wrong param** — use `content=` or `books.filter.name=`.
9. **Constructing URLs from `value`** works only for Wikipedia. Use `path`.

## Useful Complementary ZIMs

All at `download.kiwix.org/zim/<category>/`:
- **Stack Exchange** (individually, ~15-80 GB each. SO = 80 GB, frozen 2023-11)
- **Project Gutenberg** (~221 GB, literature)
- **LibreTexts** (~16 GB for 13 English subjects)
- **Wiktionary** nopic 2026-05: 8.5 GB
- **WikiMed**: 2.2 GB
- **DevDocs**: ~60 MB (28 tools, very compact)
- **iFixit**: 3.4 GB

For LLM/RAG use `nopic` variants. For travel: `maxi` (images).
See `references/zim-file-sizes.md` for exact sizes.

## Verification Checklist

- [ ] `docker compose ps` shows healthy
- [ ] Ports respond: `curl -s -o /dev/null -w '%{http_code}' http://localhost:8181`
- [ ] ZIM file fully downloaded (size matches)
- [ ] Healthchecks use `wget` + `127.0.0.1`
- [ ] nginx dark theme injects on search results
