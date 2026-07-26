---
name: bridge-tools
description: Bridge the project MCP surface into additional coding agents (Grok Build, opencode, Qwen Code, Kimi CLI) selected in .cc-suite.md. Grok, opencode, and Kimi read AGENTS.md and the shared skills tree natively, so only MCP config is mirrored, each to its own native format; Qwen Code also needs a skills symlink and does not read AGENTS.md by default.
allowed-tools:
  - Bash
  - Read
  - Edit
  - AskUserQuestion
---

# /cc-suite:bridge-tools

Mirror the project MCP surface — `.mcp.json` plus the pinned `claude-octopus` server (so each tool can delegate to, and read the session history of, Claude) — into the additional coding agents enabled in `.cc-suite.md`.

Registry-bridged tools and their native MCP targets:

| Tool | Target | China tier |
|------|--------|:---:|
| **Grok Build** (xAI) | `.grok/config.toml` (`[mcp_servers.*]`) | C — VPN-only in mainland China |
| **opencode** (SST) | `opencode.json` (`mcp`, type local/remote) | A — works natively |
| **Qwen Code** (Alibaba) | `.qwen/settings.json` (`mcpServers`, `httpUrl`) + `.qwen/skills` symlink | A — works natively |
| **Kimi CLI** (Moonshot) | `~/.kimi/mcp.json` (`mcpServers`, global) | A — works natively |

**Grok Build, opencode, and Kimi CLI** read `AGENTS.md` and the shared skills paths (`.claude/skills` / `.agents/skills`) natively, so instructions and skills need no mirroring for them.

**Qwen Code does not**, on either count. Its skill scan covers only `~/.qwen/skills/` and `.qwen/skills/` — hence the symlink in the table above — and its default context file is `QWEN.md`, so it will not pick up `AGENTS.md` without `"contextFileName": "AGENTS.md"` in `.qwen/settings.json` (a setting with an open upstream bug). If a user enables qwen and expects `AGENTS.md` to apply, tell them to symlink `QWEN.md → AGENTS.md`; the bridge does not do this for them.

Claude Code, Codex CLI, and Antigravity keep their own bridges — this command never touches them.

**Security:** env-var values and remote headers are never written into a mirrored config (potential secrets; several targets are committed). Servers that carry them are still mirrored (command/args/url), and the missing vars are reported so you can add them out of band.

## Workflow

### Step 1: Show status

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py" --status
```

This prints the enabled set (from `.cc-suite.md`, or the default `claude, codex, antigravity`) and every available tool with its China tier and MCP target. It writes nothing.

### Step 2: If no registry tools are enabled

If the status shows none of grok/opencode/qwen/kimi enabled, offer to enable some. Use `AskUserQuestion` (multi-select) listing the four with their China tiers, then add an `## Enabled Tools` section to `.cc-suite.md` (creating the file if needed) using the task-list form:

```markdown
## Enabled Tools

- [x] claude
- [x] codex
- [x] antigravity
- [ ] grok
- [ ] opencode
- [ ] qwen
- [ ] kimi
```

Tick the tools the user chose. Then continue to Step 3. If the user declines, stop here.

### Step 3: Bridge

Mirror to every enabled registry tool:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py"
```

Or bridge a one-off explicit set without editing config:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py" --tools grok,opencode
```

### Step 4: Report

Summarize per tool: which config was written (or "already current") and where, and list any env vars / headers the user must set manually. If any tool reported a user-managed name conflict (exit code 2), surface it verbatim — cc-suite refuses to overwrite a server the user owns.

Success criterion: the engine exits 0 and each enabled registry tool has an up-to-date MCP config carrying the project's servers plus `claude-code`.
