---
name: bridge-skills
description: Symlink .agents/skills/ → .claude/skills/ so Codex CLI sees all Claude skills without duplication.
allowed-tools:
  - Bash
---

# /cc-suite:bridge-skills

Create the skills bridge in the current working directory so that every skill under `.claude/skills/` is automatically available to Codex CLI (which scans `.agents/skills/`).

Idempotent. Skips if the symlink already points to the right target. Errors if `.agents/skills/` exists as a real directory (no silent overwrite).

## Workflow

### Step 1: Run the bridge script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

If the script exits non-zero, report the error output and stop. If `.claude/skills/` does not exist, report: "No `.claude/skills/` directory found — run `/cc-suite:init` first." and stop.

### Step 2: Report results

Use this template:

```markdown
**bridge-skills**: `.agents/skills/` → `.claude/skills/`

| State | Detail |
|-------|--------|
| {created / already correct / error} | {target path or error message} |
```

Success criterion: script exits 0 and `.agents/skills/` is a symlink pointing to `.claude/skills/`.
