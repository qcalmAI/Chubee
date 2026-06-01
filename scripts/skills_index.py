#!/usr/bin/env python3
"""Regenerate /mnt/chubee-data/skills/_index.json from every SKILL.md found.

Triggered by chubee-skills-index.path systemd unit on any change under
/mnt/chubee-data/skills/. Also called manually after agent-driven
skill_manage actions.
"""
import json
import os
import re
import sys
from pathlib import Path

SKILLS_ROOT = Path(os.environ.get("SKILLS_DIR", "/mnt/chubee-data/skills"))
INDEX_FILE  = SKILLS_ROOT / "_index.json"

FM_RE = re.compile(r"^---\n(.*?)\n---", re.DOTALL)


def parse_skill(skill_md: Path):
    try:
        text = skill_md.read_text(encoding="utf-8")
    except Exception as e:
        print(f"WARN: cannot read {skill_md}: {e}", file=sys.stderr)
        return None
    m = FM_RE.match(text)
    if not m:
        return None
    fm = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip().strip('"').strip("'")
    name = fm.get("name") or skill_md.parent.name
    category = fm.get("category") or skill_md.parent.parent.name
    return {
        "name": name,
        "category": category,
        "description": fm.get("description", ""),
        "version": fm.get("version", "1.0.0"),
        "path": str(skill_md.relative_to(SKILLS_ROOT)),
    }


def build():
    skills = []
    if SKILLS_ROOT.is_dir():
        for skill_md in SKILLS_ROOT.rglob("SKILL.md"):
            parsed = parse_skill(skill_md)
            if parsed:
                skills.append(parsed)
    skills.sort(key=lambda s: (s["category"], s["name"]))
    INDEX_FILE.write_text(json.dumps({"skills": skills, "count": len(skills)}, indent=2))
    return skills


if __name__ == "__main__":
    n = len(build())
    print(f"Indexed {n} skill(s) at {INDEX_FILE}")
