---
description: Refresh Claude Code convention knowledge — fetch latest docs via context7 and update the reference skill
argument-hint: "[--check | --update]"
---

## User Input

```text
$ARGUMENTS
```

## What This Does

cc-suite audits Claude Code artifacts using Codex (an OpenAI model with zero native Claude Code knowledge). All domain knowledge is stored in `skills/cc-suite/claude-code-conventions/SKILL.md`. This command refreshes that knowledge from official documentation.

## Workflow

### Step 1: Determine Mode

| Input | Mode |
|-------|------|
| `--check` | Compare current skill against latest docs, report drift (read-only) |
| `--update` | Fetch latest docs and update the skill file |
| (empty) | Default to `--check` |

### Step 2: Fetch Latest Documentation

**Prerequisite**: context7 MCP must be available. If the `mcp__plugin_context7_context7__resolve-library-id` tool is not available, report: "context7 MCP is not available. Install it with `/plugin install context7@claude-plugins-official` or manually review the official docs at https://code.claude.com/docs/en/plugins-reference." and STOP.

Query context7 for current Claude Code plugin documentation. Use these libraries in priority order:

```
1. mcp__plugin_context7_context7__resolve-library-id
   query: "claude code plugins"
   → get the library ID (likely /websites/code_claude_en_plugins or similar)

2. mcp__plugin_context7_context7__query-docs
   libraryId: {resolved ID}
   topic: "plugin structure commands agents skills hooks frontmatter plugin.json"

3. mcp__plugin_context7_context7__query-docs
   libraryId: {resolved ID}
   topic: "hooks events PreToolUse PostToolUse hook types command prompt agent"

4. mcp__plugin_context7_context7__resolve-library-id
   query: "claude code"
   → for broader docs

5. mcp__plugin_context7_context7__query-docs
   libraryId: {resolved ID for broader docs}
   topic: "CLAUDE.md settings rules configuration"
```

### Step 3: Read Current Skill

Read `${CLAUDE_PLUGIN_ROOT}/skills/cc-suite/claude-code-conventions/SKILL.md`

### Step 4: Compare and Report Drift

Compare the fetched documentation against the current skill content. Check for:

1. **New fields**: Are there plugin.json, frontmatter, or hook fields in the docs that aren't in the skill?
2. **New events**: Are there hook event types not listed in the skill?
3. **Changed schemas**: Have any field types or requirements changed?
4. **New features**: Are there new plugin capabilities (new component types, new settings) not covered?
5. **Deprecated items**: Are there items in the skill that the docs no longer mention?

### Step 5: Report (--check mode)

```markdown
# Knowledge Freshness Report

**Skill**: claude-code-conventions v{version}
**Last updated**: {date from skill}
**Checked against**: context7 ({library IDs queried})

## Drift Summary

| Area | Status | Details |
|------|--------|---------|
| plugin.json fields | CURRENT / DRIFT | {new fields found or "matches docs"} |
| Command frontmatter | CURRENT / DRIFT | ... |
| Agent frontmatter | CURRENT / DRIFT | ... |
| Skill structure | CURRENT / DRIFT | ... |
| Hook events | CURRENT / DRIFT | ... |
| Hook types | CURRENT / DRIFT | ... |
| MCP/LSP config | CURRENT / DRIFT | ... |
| Settings files | CURRENT / DRIFT | ... |

## New Items Found

| Area | Item | Details |
|------|------|---------|
| (e.g., Hook events) | (e.g., `PostToolUseFailure`) | (description from docs) |

## Deprecated Items

| Area | Item | Details |
|------|------|---------|
| (e.g., plugin.json) | (e.g., `marketplace` field) | (no longer in docs) |

## Recommendation

{CURRENT — no update needed | UPDATE RECOMMENDED — N items drifted}
```

### Step 6: Update (--update mode)

If `--update`:

1. Read the current SKILL.md
2. For each drifted section, update the content to match the latest docs
3. Update the `Last updated` date in the skill header
4. Bump the skill `version` patch number
5. Write the updated SKILL.md
6. Show a diff summary of what changed

```markdown
# Knowledge Updated

**Skill**: claude-code-conventions v{new_version}
**Previous version**: v{old_version}

## Changes Made

| Section | Change |
|---------|--------|
| Hook events | Added: `PostToolUseFailure`, `PermissionRequest` |
| plugin.json | Added field: `outputStyles` |
| ... | ... |

Run `/cc-suite:audit-plugin --mini` on this plugin to verify the update didn't break anything.
```

### Step 7: Remind about downstream updates

After updating, remind:

> The SKILL.md is updated, but the audit commands (audit-plugin, audit-skill, audit-command, audit-rules) still have inline knowledge in their prompts. For critical schema changes (new required fields, removed events), also update the affected command files. The SKILL.md is the reference; commands should defer to it for schema details rather than duplicating them.
