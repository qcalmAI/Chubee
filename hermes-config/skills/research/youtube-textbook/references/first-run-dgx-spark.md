# First run — "nvidia dgx spark", top 10 (2026-06-07)

A worked example + the caption-artifact and conflict patterns to expect.

## Outcome
- 10/10 videos transcribed, 0 caption failures.
- 131 raw facts (local Nemotron, sequential) → consolidated textbook
  `~/chubee/textbooks/nvidia-dgx-spark-20260607.md` (7.3 KB, 10 Qdrant chunks).
- Per-video fact yield was highly uneven: a 40K-char technical deep-dive gave 40 facts;
  pure-laptop videos gave 0-3; short videos gave 6-7. Uneven yield is normal — facts pool
  across all videos so per-video variance washes out at the dedup stage.

## Caption-transcription artifacts the composer must fix
YouTube auto-captions corrupt technical terms predictably. Tell the compose model to fix:
- Product/brand garbles: "DJX Spark" → "DGX Spark"; "DGXO OS" → "DGX OS".
- Technical-term garbles: "pedlops"/"pedaflops" → "petaflops".
- Garbled hardware model names (e.g. a switch transcribed "Microick CRS812") → mark `[sic]`.
- Price garbles: a "$39.99" appeared where ~$4,000 was meant — a clear transcription error;
  the composer flagged and disregarded it.

## Streaming + idle-timeout (post-hoc improvement, 2026-06-07)
The original run used non-streaming POST with a 120s wall-clock timeout. This was brittle:
long transcripts with heavy reasoning would hit the timeout and return empty. The script
was later rewritten to use SSE streaming with a 30s idle timeout:
- `"stream": True` + `select()`-based per-read timeout (5s windows).
- Idle clock resets on EVERY token (delta.reasoning OR delta.content) — as long as the
  model produces output, it waits.
- Only delta.content is accumulated into the return string; delta.reasoning resets the
  clock but is discarded. Verified: 1510 chars of reasoning → 380 chars of clean JSON.
- No fixed wall-clock cutoff. A 40K-char transcript with 3 minutes of reasoning completes
  naturally; only 30s of genuine silence triggers an abort.
- Also fixes the parallel-extraction timeout problem: concurrent requests don't need
  an inflated per-call timeout guess, because each stream independently self-regulates.

## Conflict handling (the value-add of the compose+verify stage)
Real conflicts the composer surfaced in a dedicated "Conflicting / Uncertain Data" section
rather than silently picking one:
- PRICE: $3,000 (OEM 2TB), $4,000 (Founders 4TB), "$4,700 starting", "$39.99" (error),
  "not disclosed" — present credible figures, flag the error, note which may be the
  laptop variant.
- MEMORY BANDWIDTH: 273 / 275 / "<300" GB/s — mutually consistent; but 273 GB/s is also
  the Mac mini M4 Pro figure, so sources may be conflating the two. Note it.
- UNITS: "200 Gbit/s" vs "200 GB/s aggregate" — caption unit inconsistency; flag.

## Lossless verification method
After compose, programmatically confirm every raw fact is represented: for each of the N
raw facts, check its distinctive numbers/terms appear in the textbook. Expect a handful of
FALSE-POSITIVE "missing" hits from `$`/`,` formatting in the matcher (e.g. "$4,000",
"$39.99") — eyeball those; they were all actually present. A genuinely dropped fact must
be reinstated or reported.
