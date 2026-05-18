---
description: Show the current cross-tool bridge state for this repo — AGENTS.md, imports, symlinks, MCP, hooks.
allowed-tools:
  - Bash
---

# /cc-bridge:status

Print a one-screen summary of the bridge state in the current repo:

- `AGENTS.md` — present? size?
- `CLAUDE.md` — `@AGENTS.md` import, or substantive content, or missing?
- `GEMINI.md` — same check
- `.agents/skills` — symlink to `.claude/skills`? broken? real dir? missing?
- `.codex/prompts/`, `.codex/hooks.json`, `.codex/config.toml` — present?
- `.gemini/skills/`, `.gemini/commands/` — present?
- `.mcp.json` — present? lists `codex-cli` server?
- `.gitignore` — has the cc-bridge sentinel block?

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```
