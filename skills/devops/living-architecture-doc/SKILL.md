---
name: living-architecture-doc
description: "Maintain a self-healing system-architecture document that the agent keeps current automatically via a scheduled drift-check watchdog cron — so the user never has to notice or report a change. Covers doc structure, the silent-watchdog drift detector pattern, the ~/.hermes/scripts/ cron-path constraint, and how to write detectors that don't false-positive."
author: Hermes Agent + user
version: 1.0.0
tags: [architecture, documentation, cron, watchdog, drift-detection, self-maintaining, devops]
---

# Living Architecture Doc

A class of work: produce an `ARCHITECTURE.md` (or similar system-state doc) that
explains how a system is built, **why** it's built that way, and how to rebuild
it from scratch — AND keep it current automatically, without the user having to
notice changes or remind the agent.

The user's recurring frustration this pattern solves: *"I don't want to tell you
every time something changes, and I won't even realise when something important
changes."* The answer is NOT "remember to update the doc" (the agent's memory was
wrong about the very system it documented). The answer is a **drift-check
watchdog cron** that re-derives ground truth and self-heals the doc.

## When to use

- User asks for an architecture / system-design / runbook doc for infra they own.
- A system has state that drifts between sessions (which model is loaded, which
  containers run, config that gets edited) and the agent keeps re-discovering it.
- The agent's own memory has been WRONG about live system state (a strong signal
  that point-in-time facts belong in a self-verifying doc, not memory).

## Part 1 — The doc itself

Structure that has worked:

1. **Header banner** stating "Maintained by the agent. If you change the system,
   update this file in the same turn." + a `Last verified: YYYY-MM-DD` line.
2. **Hardware / platform constraints** — the immovable facts everything else
   derives from (e.g. "one GPU = one model at a time", "unified memory").
3. **The decided architecture + WHY** — not just what, but the reasoning and the
   rejected alternatives. This is the highest-value section and the one a drift
   check must NOT clobber. Preserve it across auto-updates.
4. **Current running state** — the volatile section the watchdog verifies.
5. **Build-from-scratch steps**, ordered, each gating the next.
6. **Hard-won lessons** — mistakes made, so they're not relearned.
7. **"Keeping this doc current"** — document the cron mechanism itself, so a
   future agent reading the doc understands how it stays fresh.

Put the doc on the HOST with the stack it describes (e.g.
`~/<stack>/ARCHITECTURE.md`), version-controlled with that stack — NOT in agent
memory. Memory is for "who the user is / current operational state"; durable
system design + rebuild steps belong in a file.

## Part 2 — The drift-check watchdog (the self-healing mechanism)

### Watchdog principle: silent when correct, loud only on drift

The detector script re-derives ground truth and compares to the doc.
- **Match → print NOTHING (empty stdout) → cron delivers nothing → user sees nothing.**
- **Drift → print a `•`-bulleted report → the agent reconciles the doc + notifies.**

This is the classic watchdog: no news is good news. It must NOT chatter daily.

### Detector design rules (avoid false positives — these bite)

- **Compare bare numbers, not formatted strings.** A doc rendering `82.25×` (unicode
  ×) won't match a log emitting `82.25x` (ascii x). Strip the unit and `grep -qF`
  the bare number. Comma-formatting (`262,144` vs `262144`) is the same trap.
- **Re-derive, don't trust prior state.** Each run independently queries the live
  system (`curl /v1/models`, read config.yaml, `docker ps`, parse logs).
- **Detector reports facts; it does NOT edit the doc.** Deterministic facts diff
  cleanly; prose reasoning does not. Keep the agent (with judgement) in the loop
  for the actual prose update — the script only flags WHAT drifted.
- **Fact categories worth checking:** what a server actually serves vs what the doc
  claims; the app's configured default vs doc; "must stay empty/zero" invariants
  (e.g. a legacy config dict); measured perf numbers present in the doc's tables;
  expected-container-set membership; doc `Last verified` age (> N days → nag).

A working detector lives at `references/drift-check-pattern.md` (annotated
template — copy and adapt the facts to the system being documented).

### Cron wiring (the constraints that bit)

1. **Cron `script` paths MUST be relative to `~/.hermes/scripts/`** — absolute or
   `~/`-prefixed paths are REJECTED. If the canonical script lives with the stack
   (recommended, for version control), put a thin WRAPPER in `~/.hermes/scripts/`
   that `exec bash "$HOME/<stack>/<real-script>.sh" "$@"`, and reference just the
   wrapper filename in the cron job.
2. Use the cron job's `script` field (pre-run data collection) so the detector's
   stdout is injected as context for the agent prompt. The prompt then says:
   *"If output is empty/no drift, reply exactly SILENT and send nothing.
   Otherwise re-verify each item yourself, update the doc surgically, bump
   Last verified, and send a short report of what changed + anything that looks
   accidental (e.g. model silently reverted to a cloud provider)."*
3. `enabled_toolsets: [terminal, file]` is enough — keeps token overhead low.
4. Daily (`0 9 * * *`) is a sane default for slow-drift infra.

### The agent-side prompt contract

The cron prompt MUST instruct: re-verify every flagged fact with its own tool
calls (don't trust the script blindly), update ONLY what drifted, PRESERVE the
"why we chose X" reasoning, and never invent numbers — every figure in the doc
must come from a live tool call made that run.

## Pitfalls

- **Don't let the agent's memory be the system-of-record for volatile state.** It
  goes stale silently. The doc + drift check is the system-of-record.
- **Don't make the watchdog chatty.** If it reports on a match, the user learns to
  ignore it and real drift gets missed. Silent-on-match is non-negotiable.
- **Don't auto-rewrite prose from a script.** Scripts flag drift; the agent writes
  the prose. Auto-prose-editing destroys the "why" section.
- **Wrapper, not absolute path, for cron scripts.** See constraint 1 above.

## Related

- `vllm-serving` — the model-serving detail this pattern was first applied to.
- `hermes-cleanup` — same watchdog/silent-on-clean philosophy for ephemeral cruft.
- `tiered-model-operations` — overlaps on documenting the model-tier architecture;
  this skill is about KEEPING such a doc current, not the tiers themselves.
- `references/git-backup-watchdog.md` — the same silent-on-clean pattern applied
  to nightly Git backups of persistent state.
