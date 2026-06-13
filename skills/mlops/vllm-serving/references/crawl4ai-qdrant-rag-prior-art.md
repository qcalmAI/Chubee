# Wiring crawl4ai + Qdrant into a local agent (prior-art notes)

Condensed from a 2026-06 research pass before building a web-scrape → vector-store
RAG layer on a self-hosted stack (Hermes + crawl4ai + Qdrant + Ollama bge-m3).
Captured so a future session doesn't re-invent what the community already solved.

## The key architectural fork (decide this FIRST)

"Wire crawl4ai as the web-extract backend" and "store every page into Qdrant for
offline RAG" are **two different architectures**, not one:

- **Transparent backend** — every `web_extract` silently routes through crawl4ai.
  Almost nobody builds the auto-store-EVERYTHING variant: it bloats the vector DB
  with nav chrome, cookie banners, error pages, and dupes, and retrieval quality
  collapses. (The r/LangChain "keeping vector DBs updated" threads are full of
  this failure.)
- **Deliberate MCP capture (the proven pattern)** — explicit `crawl` / `store` /
  `rag_search` tools. Agent decides what's worth keeping. This is what the
  reference implementations actually do, and it unifies cleanly with bulk corpora
  (Gutenberg/Wikipedia) under one Qdrant + one `rag_search` surface.

## Reference implementations (forkable)

- **`coleam00/mcp-crawl4ai-rag`** — THE canonical MCP server everyone forks.
  crawl4ai → chunk → embed → vector DB → exposes `crawl` + `rag_query` as MCP
  tools. Built on the Mem0 MCP template. **Caveat: defaults to Supabase**, and the
  #1 friction in forks is ripping Supabase out for Qdrant.
- **`DinuPhan/MRE-Rag`** — containerized crawl4ai → **Qdrant** (not Supabase),
  embeddings abstracted via httpx so you can swap Gemini / OpenAI `/v1/embeddings`
  / custom endpoints. Closest to a Qdrant-native stack; use its Qdrant layer with
  coleam00's structure.
- **`mcp-server-qdrant`** (official) — thin "semantic memory" MCP over Qdrant.
- **Crawl4AI+SearXNG MCP server** (himcp.ai) — published server combining exactly
  crawl4ai + SearXNG search → crawl → RAG. Relevant if SearXNG is already running.

## Lessons (failures + wins)

1. **Don't fork coleam00 blindly** — it's Supabase-first. Take its structure,
   borrow MRE-Rag's Qdrant layer.
2. **Embedding-model coupling breaks offline.** Projects hardcoding OpenAI
   embeddings died without internet. Abstract the embedder. If `bge-m3` is already
   running on local Ollama, that's a top-tier open embedder, free + offline — a
   real advantage most of these repos lacked.
3. **Auto-store-everything = junk corpus.** Gate captures: skip error/empty pages,
   dedup by content hash, prefer deliberate capture over blanket indexing.
4. **MCP is the clean integration path on Hermes** — Hermes supports MCP natively
   (`hermes mcp add`), so an MCP server beats a bespoke web-extract-backend shim
   for the store+query use case.

## Hermes-specific wiring facts

- Hermes web_extract self-hosted hook is `FIRECRAWL_API_URL` (env), and it calls
  Firecrawl via its **Python SDK** (`_get_firecrawl_client().scrape()`), not raw
  HTTP. So routing crawl4ai through web_extract needs a shim that implements
  Firecrawl's `/v2/scrape` contract — more work than the MCP path for RAG storage.
- crawl4ai default API: `POST http://<host>:11235/crawl` with `{"urls":[...]}`.
  It refuses with `"Memory at NN%, refusing new browser"` when RAM is tight — a
  real signal to cap concurrent local-model memory, not a crawl4ai bug.
