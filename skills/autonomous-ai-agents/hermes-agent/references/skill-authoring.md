# Authoring Hermes-Agent Skills (in-repo)

## Overview

There are two places a SKILL.md can live:

1. **User-local:** `~/.hermes/skills/<maybe-category>/<name>/SKILL.md` — personal, not shared. Created via `skill_manage(action='create')`.
2. **In-repo (this reference covers this case):** `/home/bb/hermes-agent/skills/<category>/<name>/SKILL.md` — committed, shipped with the package. Use `write_file` + `git add`. `skill_manage(action='create')` does NOT target this tree.

## When to Use

- User asks you to add a skill "in this branch / repo / commit"
- You're committing a reusable workflow that should ship with hermes-agent
- You're editing an existing skill under skills/ (use `patch` for small edits, `write_file` for rewrites)

## Required Frontmatter

Source of truth: `tools/skill_manager_tool.py::_validate_frontmatter`. Hard requirements:

- Starts with `---` as the first bytes (no leading blank line).
- Closes with `\n---\n` before the body.
- Parses as a YAML mapping.
- `name` field present.
- `description` field present, ≤ **1024 chars** (`MAX_DESCRIPTION_LENGTH`).
- Non-empty body after the closing `---`.

Peer-matched shape:

```yaml
---
name: my-skill-name               # lowercase, hyphens, ≤64 chars
description: Use when <trigger>. <one-line behavior>.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [short, descriptive, tags]
    related_skills: [other-skill, another-skill]
---
```

## Size Limits

- Description: ≤ 1024 chars (enforced).
- Full SKILL.md: ≤ 100,000 chars (enforced as `MAX_SKILL_CONTENT_CHARS`, ~36k tokens).
- Peer skills sit at **8-14k chars**. Aim for that range. If past 20k, split into `references/*.md`.

## Peer-Matched Structure

Every in-repo skill follows roughly:

```
# <Title>

## Overview
One or two paragraphs: what and why.

## When to Use
- Bulleted triggers
- "Don't use for:" counter-triggers

## <Topic sections specific to the skill>

## Common Pitfalls
Numbered list of mistakes and their fixes.

## Verification Checklist
- [ ] Checkbox list of post-action verifications
```

Not every section is mandatory, but `Overview` + `When to Use` + actionable body + pitfalls are the minimum.

## Directory Placement

```
skills/<category>/<skill-name>/SKILL.md
```

Categories currently in repo: `autonomous-ai-agents`, `creative`, `data-science`, `devops`, `dogfood`, `email`, `gaming`, `github`, `leisure`, `mcp`, `media`, `mlops/*`, `note-taking`, `productivity`, `red-teaming`, `research`, `smart-home`, `social-media`, `software-development`.

## Workflow

1. **Survey peers** in the target category: `ls skills/<category>/`
2. Read 2-3 peer SKILL.md files to match tone and structure.
3. **Check validator constraints** in `tools/skill_manager_tool.py` if unsure.
4. **Draft** with `write_file` to `skills/<category>/<name>/SKILL.md`.
5. **Validate locally** — see validation pattern below.
6. **Git add + commit** on the active branch.

## Validating Frontmatter Before Deployment

```python
import yaml

content = open('/tmp/skill-rewrite.md').read()
assert content.startswith('---'), "Missing opening ---"
parts = content.split('---', 2)
assert len(parts) >= 3, "Malformed frontmatter"
fm = yaml.safe_load(parts[1])
assert 'name' in fm, "Missing name"
assert 'description' in fm, "Missing description"
assert len(fm['description']) <= 1024, f"Description too long: {len(fm['description'])}"
assert len(content) <= 100_000, f"Content too long: {len(content)}"
body = parts[2].strip()
assert body, "Empty body after frontmatter"
```

## Dockerized Hermes: Permission Pitfall (CRITICAL)

When Hermes runs in a Docker container, `~/.hermes/` is bind-mounted to `/opt/data/`.
The gateway runs as a non-root UID (e.g. 10000), and files under `~/.hermes/skills/`
are owned by that UID — the **host user (UID 1000) cannot write to them**.

**The Fix: Write to /tmp, deploy via docker cp**

```bash
# 1. Write the file to a temp path the host user CAN write to:
write_file("/tmp/skill-rewrite.md", content)

# 2. Copy into the container:
docker cp /tmp/skill-rewrite.md hermes:/opt/data/skills/<category>/<name>/SKILL.md

# 3. For references/scripts/templates, create the dir first:
docker exec hermes mkdir -p /opt/data/skills/<category>/<name>/references
docker cp /tmp/ref-file.md hermes:/opt/data/skills/<category>/<name>/references/file.md
```

### Path Mapping

| `skill_view` reports | Host filesystem | Container (docker exec) |
|---|---|---|
| `/opt/data/skills/<name>/SKILL.md` | `~/.hermes/skills/<name>/SKILL.md` | same as skill_view |
| Path doesn't exist on host | Use `sudo` to read if needed | Use `docker cp` to write |

## Common Pitfalls

1. **Using `skill_manage(action='create')` for an in-repo skill.** It writes to `~/.hermes/skills/`, not the repo tree. Use `write_file` for in-repo creation.
2. **Leading whitespace before `---`.** The validator checks `content.startswith("---")`; any leading blank line or BOM fails validation.
3. **Description too generic.** Peer descriptions start with "Use when ..." and describe the *trigger class*, not the one task.
4. **Forgetting the author/license/metadata block.** Not validator-enforced, but every peer has it.
5. **Writing a skill that duplicates a peer.** Before creating, `ls skills/<category>/` and open 2-3 peers. Prefer extending an existing skill.
6. **Expecting the current session to see the new skill.** The skill loader is initialized at session start. Verify in a fresh session.
7. **Linking to skills that don't exist in-repo.** `related_skills: [some-user-local-skill]` works for you but breaks for other clones.
8. **Dockerized Hermes: `write_file` silently fails on skill paths.** See "Dockerized Hermes: Permission Pitfall" above.
9. **`skill_view` paths are container-internal.** `/opt/data/skills/...` is the mount point inside the container. Don't pass these to `write_file` on a Dockerized install.
