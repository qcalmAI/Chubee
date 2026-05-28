CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS memories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content       TEXT NOT NULL,
  category      TEXT NOT NULL,
  importance    INTEGER NOT NULL DEFAULT 5 CHECK (importance BETWEEN 1 AND 10),
  source        TEXT,
  embedding     vector(1024),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_recalled TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS memories_embedding_idx ON memories
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50);
CREATE INDEX IF NOT EXISTS memories_category_idx ON memories(category);
CREATE INDEX IF NOT EXISTS memories_importance_idx ON memories(importance DESC);
CREATE INDEX IF NOT EXISTS memories_created_at_idx ON memories(created_at DESC);

CREATE TABLE IF NOT EXISTS url_allowlist (
  domain   TEXT PRIMARY KEY,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  notes    TEXT
);

INSERT INTO url_allowlist (domain, notes) VALUES
  ('wikipedia.org', 'Reference'),
  ('arxiv.org', 'Papers'),
  ('github.com', 'Code references'),
  ('docs.anthropic.com', 'API documentation')
ON CONFLICT DO NOTHING;
