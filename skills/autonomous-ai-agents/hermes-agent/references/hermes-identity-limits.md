# SOUL.md & Identity Limits — Reference

Source: https://hermes-agent.nousresearch.com/docs/user-guide/features/personality/
Source: https://hermes-agent.nousresearch.com/docs/guides/use-soul-with-hermes/

## SOUL.md

- **Default path:** `~/.hermes/SOUL.md` (or `$HERMES_HOME/SOUL.md`)
- **Cap:** 20,000 characters with smart head/tail truncation
- **Recommended:** 4–8 lines defining identity, tone, and constraints
- **Slot:** #1 in system prompt — replaces built-in default identity entirely
- **Reload:** Fresh each message — no restart for SOUL.md changes
- **First-run:** Auto-seeded if missing; never overwrites existing files
- **Fallback:** If empty or unloadable, Hermes uses built-in default identity
- **Security:** Scanned for prompt-injection patterns before injection
- **No wrapper text added** — the content itself IS the identity

### Good SOUL.md traits
- Stable, broadly applicable, specific in voice
- Not overloaded with temporary instructions

### Bad SOUL.md traits
- Full of project details
- Contradictory instructions
- Micro-managing every response shape
- Generic filler like "be helpful" / "be clear" — already defaults

## Personality Presets

- **Location:** `config.yaml` → `agent.personalities.<name>`
- **No explicit cap** but practical limit is YAML readability (~150–500 chars)
- **Activation:** `/personality <name>` in-session, or `display.personality: <name>` auto-load
- **Use:** Session-level temporary overlays, NOT durable identity

## AGENTS.md (per-project)

- **Cap:** 8,000 characters per file
- **Use:** Project-specific conventions (commands, paths, architecture)
- **Load rule:** First match per directory from AGENTS.md / CLAUDE.md / .cursorrules

## Memory Limits (from config.yaml)

- `memory.memory_char_limit`: 2,200 chars
- `memory.user_char_limit`: 1,375 chars

## CLI Alias

- `hermes profile alias <profile> --name <alias>` creates wrapper at `~/.local/bin/<alias>`
- Simple shell alias: `alias chubee='hermes'` in `~/.bashrc` or `~/.zshrc`
