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

**Qwen Code does not**, on either count — so the bridge compensates twice for it. Its skill scan covers only `~/.qwen/skills/` and `.qwen/skills/`, hence the symlink in the table above. Its default context file is `QWEN.md` (qwen-code 0.21.0 resolves `["QWEN.md"]` whenever the setting is unset), so the bridge also writes `context.fileName: ["AGENTS.md", "QWEN.md"]` into `.qwen/settings.json`. Both are automatic; do not tell the user to hand-symlink `QWEN.md`.

If a user reports that qwen is ignoring `AGENTS.md`, check that `.qwen/settings.json` carries that `context.fileName` array — if it is missing, the project was bridged by an older cc-suite and needs a re-run of this command.

Claude Code, Codex CLI, and Antigravity keep their own bridges — this command never touches them.

**Security:** env-var values and remote headers are never written into a mirrored config (potential secrets; `.grok/config.toml`, `opencode.json`, and `.qwen/settings.json` are routinely committed to the repo). Servers that carry them are still mirrored (command/args/url), and the missing vars are reported so you can add them out of band.

## Workflow

### Step 1: Show status

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py" --status
```

This prints the enabled set (from `.cc-suite.md`, or the default `claude, codex, antigravity`) and every available tool with its China tier and MCP target. It writes nothing.

If the script exits non-zero, report the error output and stop.

### Step 2: If no registry tools are enabled

If the status shows none of grok/opencode/qwen/kimi enabled, offer to enable one or more of the four. Use `AskUserQuestion` (multi-select) listing the four with their China tiers, then add an `## Enabled Tools` section to `.cc-suite.md` (creating the file if needed) using the task-list form:

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

If the script exits non-zero for any reason other than the exit-code-2 conflict handled in Step 4, report the error output and stop.

### Step 4: Report

Display:

```markdown
**bridge-tools**: MCP surface mirrored to the enabled registry tools

| Tool | Config written | Status |
|------|----------------|--------|
| {tool-name} | {target-path} | mirrored / already current |

**Set manually**: {env vars and remote headers per tool, or "none"}
**Conflicts**: {any exit-code-2 user-managed name conflicts, verbatim, or "none"}
```

If any tool reported a user-managed name conflict (exit code 2), surface it verbatim — cc-suite refuses to overwrite a server the user owns.

Success criterion: the engine exits 0 and each enabled registry tool has an up-to-date MCP config carrying the project's servers plus `claude-code`.
