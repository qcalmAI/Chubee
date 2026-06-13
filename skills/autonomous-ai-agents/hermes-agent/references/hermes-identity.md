# Hermes Agent Identity Customization

Three mechanisms control who the agent is, what it calls itself, and how it speaks. They layer on top of each other — understanding the layering is key to knowing which to use when.

## The Identity Stack

```
SOUL.md (slot #1 — durable baseline, replaces default identity)
     ↓  overridden by
/personality <name>  (session-level overlay, temporary)
     ↓  further shaped by
Memory & Skills  (facts and procedures, not identity)
```

### 1. SOUL.md — Durable Core Identity

**Path:** `~/.hermes/SOUL.md` (or `$HERMES_HOME/SOUL.md`)

**The primary identity file.** Slot #1 in the system prompt — it defines who the agent IS. Completely replaces the built-in default identity.

**Character limit:** **20,000 chars** with smart head/tail truncation. However, the official guidance recommends **4–8 lines** (~300–800 chars). Past that, instructions start fighting each other and truncation may clip important content.

**Reload behavior:** Loaded fresh each message — no restart needed after editing.

**First-run behavior:** Hermes auto-seeds a starter `SOUL.md` on first run. It never overwrites an existing file.

**What it's for:**
- Tone, personality, communication style
- How direct or warm the agent should be
- Stylistic constraints ("no hype language", "avoid sycophancy")
- How the agent relates to uncertainty and disagreement

**What it's NOT for:**
- Project-specific instructions (use `AGENTS.md`)
- File paths, commands, service ports, architecture notes
- Workflow instructions

**Example structure:**

```markdown
# Identity
You are Chubee, a pragmatic senior engineer built on Hermes Agent.

# Style
- Be direct and concise unless complexity requires depth
- Say when something is a bad idea
- Prefer practical tradeoffs over idealized abstractions

# Avoid
- Sycophancy, hype language, overexplaining obvious things
```

### 2. Personality Presets — Session-Level Overlays

**Location:** `~/.hermes/config.yaml` → `agent.personalities.<name>`

**Character limit:** No explicit hard cap, but they're YAML strings — keep them **1–3 sentences** (~150–500 chars). Longer presets clutter the system prompt and dilute SOUL.md.

**Activation:**
- In-session: `/personality <name>`
- Config auto-load: `display.personality: <name>` in config.yaml
- CLI: `hermes -p <profile> --personality <name>`

**Use case:** Temporary mode switching. Don't duplicate SOUL.md here.

**Examples from a typical config:**

```yaml
agent:
  personalities:
    teacher: You are a patient teacher. Explain concepts clearly with examples.
    concise: You are a concise assistant. Keep responses brief and to the point.
    surfer: Duuude! You're chatting with the chillest AI on the web, bro!
```

### 3. CLI Alias — Renaming the `hermes` Command

Two approaches to make `chubee` work as a shell command:

**a) Simple alias** (recommended, add to `~/.bashrc` or `~/.zshrc`):
```bash
alias chubee='hermes'
```

**b) `hermes profile alias`** — creates a standalone wrapper script:
```bash
hermes profile alias default --name chubee
```
Creates `~/.local/bin/chubee` as a full wrapper script. Also works with named profiles:
```bash
hermes profile alias work --name chubee-work
```

## Context File Limits Reference

| File | Hard cap | Recommended size |
|------|----------|-----------------|
| `SOUL.md` | 20,000 chars (smart truncation) | 4–8 lines / ~300–800 chars |
| Personality preset (config.yaml) | No explicit cap (YAML string) | 1–3 sentences / ~150–500 chars |
| `AGENTS.md` (per-project) | 8,000 chars | Project conventions only |
| Memory store (notes) | 2,200 chars | Facts, not identity |
| Memory store (user profile) | 1,375 chars | User preferences |

## Common Pitfalls

- **`approvals.mode: false` (YAML boolean) silently breaks approval bypass.** The
  config expects the STRING `'off'` / `'manual'` / `'smart'`. A bare `false` is
  parsed as a boolean, coerced to the default (prompt-on-destructive), and the
  user keeps getting approval prompts despite thinking they disabled them. This
  is NOT an OS-sudo issue — passwordless sudo can be working fine while Hermes'
  own approval gate is what prompts. Fix: `hermes config set approvals.mode off`
  or set `mode: 'off'` (quoted string) in config.yaml. General rule: Hermes
  enum-style config keys want quoted strings, not YAML booleans — verify the
  written value's TYPE, not just its presence.
- **Keep SOUL.md ruthlessly dense — match the existing line density when editing.**
  The user invests real effort compressing SOUL.md to info-dense 1–2 line
  fragments. When adding a directive, write it as ONE tight line in the same
  voice, not a 5–6 line paragraph with rhetorical padding ("this is not optional
  caution", restating the point twice). A new rule should add ~150 chars, not
  ~430. Lossless on the instruction, zero filler. Show the before/after and the
  byte delta when the user asks to verify you didn't bloat it.
- **Putting project instructions in SOUL.md.** Move them to AGENTS.md. SOUL.md should be universally applicable.
- **Overloading SOUL.md.** More than ~800 chars and instructions start conflicting. The guide says "a weak SOUL is contradictory or full of generic filler."
- **Empty SOUL.md.** If the file exists but is empty, it's ignored and the built-in default identity is used. Delete it if you want the default back.
- **Personality overrides SOUL.md.** `/personality teacher` replaces the baseline. The agent won't sound like SOUL.md while a personality is active.
- **Editing without restarting session.** SOUL.md loads per-session in CLI mode. In gateway mode, use `/restart` (or start a new DM topic).
