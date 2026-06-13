# Operational Notes — docker-compose-services

## .env-driven secrets vanish on recreate (2026-06-07)

Several services read secrets from `~/chubee/stack/.env` (`CRAWL4AI_API_TOKEN`,
`SEARXNG_SECRET`, etc.). A running container holds whatever value it got at first
start — but `docker compose up -d --force-recreate <svc>` re-reads `.env` and
substitutes a **blank string** for any var no longer present, silently
de-authenticating the service. This happens when `.env` was trimmed (e.g.
relic-service cleanup) without noticing a still-in-use key went with it.

- The recreate warns: `The "FOO" variable is not set. Defaulting to a blank string.`
  WATCH for that line — it means a live secret just got blanked.
- Before recreating a service that uses an `.env` secret, confirm the key is present:
  `grep -c '^CRAWL4AI_API_TOKEN=' ~/chubee/stack/.env` (expect 1, not 0).
- Restore from the newest `.env.bak.*` if missing, then recreate. Keep the backups.
- Reading a secret back from a live container: write it to a file via redirection
  rather than inline `$(docker exec … printenv …)` — token values containing
  shell-special chars corrupt command substitution.

## Memory saturation from vLLM reservation (2026-06-07)

On the GB10, vLLM reserves `gpu-memory-utilization × 119.7 GiB` of the UNIFIED pool,
so `free -h` legitimately shows ~97% used even at idle (GPU-reserved, not process RSS).
Consequence: other services with memory guards refuse to work. Example — **crawl4ai**
has `memory_threshold_percent: 95.0` and refused every crawl ("Memory at 97.0%,
refusing new browser").

Two fixes (prefer the second long-term):
1. Raise the co-located service's guard. For crawl4ai, edit `memory_threshold_percent`
   to 99.5 and make it durable by bind-mounting the config.
2. Lower vLLM's `--gpu-memory-utilization` to free real headroom (see `vllm-serving`
   — 0.85→0.60 frees ~30 GiB). This removes the root cause.

## `docker compose up -d` can trip foreground guard

The terminal tool may refuse `docker compose up -d ...` thinking it starts a server
that won't return. It's actually a detached one-shot. Run with `background=true` +
`notify_on_complete=true` rather than fighting the foreground guard.

## Old `providers` dict shadows `custom_providers`

Hermes v0.15.x resolves custom providers by checking the old `providers:` dict FIRST.
If both old and new formats exist with different `base_url` values, the old one wins
and requests silently fall through to OpenRouter (404). See `vllm-serving` for full
diagnosis and fix.
