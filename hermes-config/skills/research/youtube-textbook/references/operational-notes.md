# Operational Notes — youtube-textbook

## Streaming + idle-timeout evolution (2026-06-07)

The original extraction used non-streaming POST with a 120s wall-clock timeout.
This was brittle: long transcripts with heavy reasoning would hit the timeout
and return empty. The script was rewritten to use SSE streaming with a 30s idle
timeout:
- `"stream": True` + `select()`-based per-read timeout (5s windows).
- Idle clock resets on EVERY token (delta.reasoning OR delta.content) — as long
  as the model produces output, it waits.
- Only `delta.content` is accumulated; `delta.reasoning` resets the clock but is
  discarded. Verified: 1510 chars of reasoning → 380 chars of clean JSON.
- No fixed wall-clock cutoff. A 40K-char transcript with 3 minutes of reasoning
  completes naturally; only 30s of genuine silence triggers an abort.

This also fixed the parallel-extraction timeout problem: concurrent requests
don't need an inflated per-call timeout guess, because each stream independently
self-regulates.

## Parallel extraction worked once bugs were fixed

vLLM does batch concurrent requests fine (probed: 4 running at once with
`num_requests_running=4.0, waiting=0.0`). The earlier "parallel returns empty"
failure was NOT a vLLM serialization limit; it was:
(a) a too-short fixed wall-clock timeout, and
(b) bash `wait $pids` mismanaging child PIDs.

## The compose-model-pinning gotcha

`delegate_task` inherits the session's CURRENT default model — there is no
per-call model argument. On one run, `anthropic/claude-opus-4.8` was the live
default, so compose ran on Opus instead of specified DeepSeek-V4-Flash. Quality
was fine but it was NOT the specified model. Always verify and report the actual
compose model every run.

## 0-facts diagnostic detail

"0 facts + no error" is ambiguous. Causes observed:
1. Video genuinely off-scope (correct).
2. Scope wording too exclusionary — model rejected a mixed video wholesale
   (e.g. a DGX+RTX video returned 0 facts when scope said "EXCLUDE RTX Spark
   laptops").
3. Long transcript caused reasoning runaway before chunking was added.

Diagnosis: if a clearly on-topic video returns 0, re-test that one transcript
standalone with a neutral scope before trusting the 0.

## Context window limit for compose

The compose step must fit the full extracted facts JSON + instructions in
DeepSeek V4 Flash's context window. For very large batches (50+ videos ×
many facts), chunk the compose or use a model with larger context.
