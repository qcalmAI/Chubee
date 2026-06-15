---
name: youtube-textbook
description: "Build a canonical reference textbook from YouTube — given a creator, channel/video URL, or topic, transcribe relevant videos, extract atomic facts (local Nemotron), dedup across videos, and compose the shortest document that retains every relevant fact (verified best-effort). Use when the user says 'build a textbook from <channel>' or 'search youtube and make a textbook on <topic>'."
version: 1.1.0
author: Quinton Calmus
license: MIT
metadata:
  hermes:
    tags: [youtube, textbook, knowledge-compilation, nemotron, deepseek]
    related_skills: [youtube-content, knowledge-query]
---

# YouTube Textbook — canonical fact compilation from a channel or topic

## What this does
Input: a creator name, channel URL, single video URL (→ its channel), or a topic string.
Output: the shortest possible markdown document containing every relevant, substantive
fact from the selected videos, with cross-video redundancy consolidated.

**Verified retention (best-effort) on relevant facts; aggressively lossy on chatter**
(creator bios, sponsor reads, like-and-subscribe, intros/outros, filler).

## CRITICAL — model assignment (state this to the user at the confirmation gate)
- **Per-video fact extraction → LOCAL Nemotron** (`extract_facts.py`, vLLM :8000).
  Free, sovereign, parallel. This is the bulk labor.
- **⚠️ Orchestration + dedup + composition + verification → DeepSeek V4 Flash
  (OpenRouter) — NON-LOCAL CLOUD MODEL.** ALWAYS emphasize this at the gate.
  **PIN THE MODEL when delegating the compose step.** `delegate_task` inherits the
  session's current default — if that's Opus, compose silently runs on Opus.
  Set the session default to `frontier`/`deepseek-v4-flash` before delegating,
  or report which model actually ran. Observed deviation: a run executed on
  `anthropic/claude-opus-4.8` — verify and report the actual compose model every run.

## Scripts (in skill: scripts/)
- `yt_resolve.py "<input>" [--limit N]` → JSON `{mode, resolved, count, videos:[{id,title,url}]}`.
  Topic default cap = 30. Auto-detects topic vs channel vs video-URL.
- `extract_facts.py --title T --scope S --vid ID` (transcript on stdin) → JSON
  `{vid,title,facts:[{topic,fact}]}`. Runs LOCAL Nemotron via STREAMING with 30s
  IDLE TIMEOUT — no fixed wall-clock cutoff. Reasoning tokens reset the idle clock
  but are discarded; only `delta.content` surfaces. Chunks long transcripts internally
  (12K-char windows) — mandatory for big videos.
- Transcripts from the `youtube-content` skill, run inside the hermes container:
  `docker exec hermes python3 /opt/data/skills/media/youtube-content/scripts/fetch_transcript.py "<url>" --text-only`

## Procedure

### 1. Resolve + 🚧 CONFIRMATION GATE (mandatory)
Run `yt_resolve.py`. Then STOP and present to the user:
- Mode (topic/channel/video→channel), resolved name, **video count + titles**.
- The **model split**, emphasizing the DeepSeek-V4-Flash (cloud) portion.
- The **relevance scope**: if the user gave one, state it. If not, say you'll
  infer from transcripts and ask. (Defer to gate #2 after a quick sample, but
  surface the ambiguity HERE.)
- **Any ambiguity** (topic interpretation, borderline channel, cap concerns).
Do not proceed until the user approves.

### 2. Transcribe
For each video, fetch captions via the container script. Track videos with NO
captions — do not Whisper them this version. Save transcripts to a TEMP dir
(`/tmp/yt-textbook-<run>/`), deleted at the end.

### 3. Extract facts — LOCAL Nemotron
Run `extract_facts.py` across transcripts with the agreed `--scope`. Collect all
`{topic,fact}` across videos, tagged by source vid.

- vLLM **does** batch concurrent requests (probed: 4 running at once). Earlier
  parallel failures were timeout/bug issues, not vLLM limits.
- `extract_facts.py` uses streaming + 30s idle timeout — no fixed wall-clock
  cutoff. As long as tokens flow, it waits. Only aborts on 30s of genuine silence.
- Sequential is the conservative fallback (~25-90s per chunk).
- For large batches (5+ videos), detach via `setsid` + log file (see Pitfalls).

### 3a. Scope wording — avoid over-aggressive exclusion
When scope EXCLUDES a related product, phrase it so the model still extracts
in-scope facts from MIXED videos. A blunt "EXCLUDE X" makes the model reject
the whole video. Correct: "Extract <target> facts even when mixed with <other>;
only skip facts EXCLUSIVELY about <other>; when a spec could apply to <target>,
include it." Put scope in a FILE and read it (`SCOPE=$(cat scope.txt)`) —
long scope strings break shell quoting when inlined.

### 3b. 🚧 SCOPE GATE (only if scope was NOT given)
Cluster extracted topics and ask which COARSE topics to keep (e.g. "channel
covers gardening + woodworking + dog vlogs — which?"). Never ask about granular
facts — on-topic facts are always kept.

### 4. Dedup + compose (DeepSeek V4 Flash)
- Cluster facts by topic across all videos. Merge overlaps: repeated facts
  collapse to ONE statement each. Preserve every DISTINCT fact and all specifics
  (numbers, quantities, tool/material names).
- Compose the textbook: organized by topic, shortest form per fact, no repetition.

### 5. 🔒 VERIFIED RETENTION (best-effort — do not skip)
Take the full extracted-facts list and confirm every fact appears (semantically)
in the final textbook. List any facts that were dropped; either reinstate them
or report them to the user. An LLM will silently drop facts when compressing;
the verify pass is the only thing that makes "verified retention" real.

**Caveat:** an LLM checking its own output can false-positive (finding a fact that
isn't actually retained) or false-negative (missing a fact that is). Eyeball
disputed hits. A genuinely dropped fact must be reinstated or reported.

### 6. Store
- Markdown → `~/chubee/textbooks/<slug>-<YYYYMMDD>.md` (slug = channel/topic).
  Front-matter: source, mode, video count, date, caption-less list.
- Embed into the shared **`chubee_textbooks`** Qdrant collection (1024-dim Cosine,
  bge-m3), chunked, payload tagged `{source, slug, topic, chunk}`. Queryable via
  `knowledge-query`. Create collection if missing.

### 7. Clean up + report
- DELETE the temp transcripts + intermediate fact JSON.
- Report: textbook path, fact count, topic sections, and **"N videos processed,
  M had no captions: [titles]."**

## Pitfalls

- **Confirmation gate is mandatory** — never burn transcription/extraction compute
  on dozens of videos before the user confirms scope + count.
- **Topic search relevance degrades past ~30 results.** Default cap 30 is deliberate.
- **yt-dlp on HOST** (`~/.local/bin/yt-dlp`), not container. Transcript fetch in container.
  Resolve = host, transcribe = `docker exec`.
- **Don't claim verified retention without step 5.** The verify pass is the only guard
  against silent fact-dropping during compression.
- **Watcher kills long extract batches (exit -15).** Large batches of `extract_facts.py`
  (5+ videos) via `terminal(background=true)` get SIGTERM'd after ~300s. Detach with
  `setsid` + log file:
  ```bash
  docker exec hermes setsid bash -c '
    for vid in <VIDS>; do
      cat "$RUN/transcripts/$vid.txt" | python3 extract_facts.py --title T --scope S --vid "$vid" > "$RUN/facts/$vid.json" 2>/dev/null
    done
  ' > /tmp/yt-extract-<run>.log 2>&1
  ```
  Poll with `tail -n5 /tmp/yt-extract-<run>.log`. `setsid` detaches from the watcher's
  process tree.
- **0 facts + no error is ambiguous.** Either genuinely off-scope, OR scope wording
  too exclusionary, OR long transcript ran away on reasoning before chunking. If a
  clearly on-topic video returns 0, re-test standalone with neutral scope.
- **Nemotron occasionally returns empty content** — `extract_facts.py` retries once.
  If persistent on long transcripts, increase `max_tokens` (currently 3000).
- For operational history and detailed incident patterns, see
  `references/operational-notes.md`.

## Worked example
`references/first-run-dgx-spark.md` — first live run (top-10 "nvidia dgx spark"):
per-video yields, caption-artifact fix list, conflict-handling patterns, and the
verification pass. Read before a run.
