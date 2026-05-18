---
description: Symlink .claude/skills/ → .agents/skills/ so Codex CLI sees all Claude skills without duplication.
allowed-tools:
  - Bash
---

# /cc-bridge:bridge-skills

Create the skills bridge in the current working directory so that every skill under `.claude/skills/` is automatically available to Codex CLI (which scans `.agents/skills/`).

Idempotent. Skips if the symlink already points to the right target. Errors if `.agents/skills/` exists as a real directory (no silent overwrite).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

Report what changed.
