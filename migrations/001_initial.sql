-- v5.0 initial schema migration
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Two-tier memory: bounded snapshot (always in context)
CREATE TABLE IF NOT EXISTS memory_snapshot (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  target      TEXT NOT NULL CHECK (target IN ('user', 'memory', 'system')),
  key         TEXT NOT NULL,
  content     TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (target, key)
);

-- Episodic memory: full-text + vector searchable
CREATE TABLE IF NOT EXISTS episodic_memory (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content     TEXT NOT NULL,
  category    TEXT,
  importance  INT DEFAULT 3 CHECK (importance BETWEEN 1 AND 10),
  source      TEXT,
  embedding   vector(1024),
  fts         TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS episodic_memory_embedding_idx
  ON episodic_memory USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
CREATE INDEX IF NOT EXISTS episodic_memory_fts_idx
  ON episodic_memory USING GIN (fts);
CREATE INDEX IF NOT EXISTS episodic_memory_trgm_idx
  ON episodic_memory USING GIN (content gin_trgm_ops);

-- Session messages: full-text searchable conversation log
CREATE TABLE IF NOT EXISTS session_messages (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  TEXT NOT NULL,
  role        TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
  content     TEXT NOT NULL,
  model       TEXT,
  fts         TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS session_messages_session_idx
  ON session_messages (session_id, timestamp);
CREATE INDEX IF NOT EXISTS session_messages_fts_idx
  ON session_messages USING GIN (fts);
CREATE INDEX IF NOT EXISTS session_messages_timestamp_idx
  ON session_messages (timestamp DESC);

-- Skills metadata: index of agent-curated procedural memory
CREATE TABLE IF NOT EXISTS skills_metadata (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        TEXT NOT NULL UNIQUE,
  title       TEXT NOT NULL,
  description TEXT,
  category    TEXT,
  path        TEXT NOT NULL,
  use_count   INT DEFAULT 0,
  last_used   TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- URL allowlist for web ingestion
CREATE TABLE IF NOT EXISTS url_allowlist (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern     TEXT NOT NULL UNIQUE,
  added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO url_allowlist (pattern) VALUES
  ('https://news.ycombinator.com/%'),
  ('https://arxiv.org/%'),
  ('https://github.com/%'),
  ('https://en.wikipedia.org/%')
ON CONFLICT (pattern) DO NOTHING;
