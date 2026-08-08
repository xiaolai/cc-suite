---
description: "Shared: resolve plugin root, validate manifest, discover all artifacts, build cross-reference map"
user-invocable: false
---
<!-- Shared partial: plugin artifact discovery for Claude Code plugin directories -->
<!-- Referenced by: audit-plugin. Do not use standalone. -->

## Plugin Discovery

### Resolve Plugin Root

Determine the plugin directory from `{plugin_dir}` (extracted from `$ARGUMENTS` by the calling command). A plugin directory is one that contains `.claude-plugin/plugin.json`.

**Case 1 — a path was given** (`{plugin_dir}` is a non-empty relative or absolute path):

- Resolve it and look for `.claude-plugin/plugin.json`.
- If found → set `{plugin_root}` to that directory and continue to *Read Plugin Manifest*.
- If NOT found → respond: "No `.claude-plugin/plugin.json` found in `{resolved_path}` — not a Claude Code plugin directory. Re-run with no path to choose from your installed plugins." and STOP.

**Case 2 — no path was given** (`{plugin_dir}` is empty). Do NOT blindly audit the current working directory — most directories are ordinary projects, not plugins. Resolve in this order:

- **2a.** If the current working directory contains `.claude-plugin/plugin.json` → use it as `{plugin_root}` (you are inside a plugin under development) and continue.
- **2b.** Otherwise, enumerate the user's installed plugins and let them choose:
  1. Read `~/.claude/plugins/installed_plugins.json` (schema `{version, plugins}` where each key is `"<name>@<marketplace>"` and each value is a list of install records, each holding `scope`, an optional `projectPath`, `installPath`, and `version`).
  2. If that file is missing or empty, fall back to globbing `~/.claude/plugins/cache/*/*/*/.claude-plugin/plugin.json` and `~/.claude/plugins/marketplaces/*/plugins/*/.claude-plugin/plugin.json`.
  3. Present the discovered plugins with `AskUserQuestion` (option label = `<name>@<marketplace> vX.Y.Z`; up to 4 per question — page through groups if there are more; the user may also type a path via "Other").
  4. Set `{plugin_root}` to the chosen plugin's `installPath` and continue. When a plugin has more than one install record, pick the record whose `projectPath` equals the current working directory's project root; if none matches, pick the `scope: "user"` record; if there is none, pick the first record.
- **2c.** If NO installed plugins are found either → respond: "No plugin directory given and the current directory is not a plugin, and no installed plugins were found. Pass a path: `/cc-suite:audit-plugin <path-to-plugin>`." and STOP.

### Read Plugin Manifest

Read `.claude-plugin/plugin.json` and extract:
- `{plugin_name}` — the `name` field
- `{plugin_version}` — the `version` field
- `{plugin_description}` — the `description` field

If any required field (`name`) is missing, note it as a finding for the calling command.

### Discover Artifacts

Glob for all plugin artifacts under `{plugin_root}`:

| Category | Pattern | Expected frontmatter |
|----------|---------|---------------------|
| Commands | `commands/*.md` | `description` (required) |
| Shared partials | `commands/shared/*.md` | `user-invocable: false` (required) |
| Agents | `agents/*.md` | `description` (required) |
| Skills | `skills/*/SKILL.md` | Skill metadata |
| Hooks | `hooks/hooks.json` | JSON object; `hooks` keyed by event (`SessionStart`, `PostToolUse`, …), each an array of hook groups |
| MCP config | `.mcp.json` | JSON with `mcpServers` |
| Marketplace | `.claude-plugin/marketplace.json` | Marketplace manifest |

For each `.md` artifact found:
1. Read the file
2. Parse YAML frontmatter (between `---` delimiters)
3. Extract the markdown body (everything after frontmatter)
4. Store: `{artifact_path}`, `{artifact_type}`, `{frontmatter}`, `{body}`

For JSON artifacts (`hooks.json`, `.mcp.json`, `marketplace.json`):
1. Read and parse the JSON
2. Store: `{artifact_path}`, `{artifact_type}`, `{parsed_json}`

### Build Cross-Reference Map

Scan artifact bodies for references to other artifacts:

- **Command → shared partial**: Look for `commands/shared/*.md` references in command bodies
- **Command → agent**: Look for agent name references
- **Agent → skill**: Look for skill name references in agent descriptions
- **Hook → script**: Look for script paths in hook definitions (`command` fields)

Store as `{cross_refs}`: a list of `{source_artifact}` → `{target_artifact}` → `{ref_type}` triples.

### Output Inventory

Display the plugin inventory to the user:

```markdown
## Plugin Inventory: {plugin_name} v{plugin_version}

> {plugin_description}

| Category | Count | Artifacts |
|----------|-------|-----------|
| Commands | N | cmd1, cmd2, ... |
| Shared Partials | N | partial1, partial2, ... |
| Agents | N | agent1, agent2, ... |
| Skills | N | skill1, skill2, ... |
| Hooks | N | hook1, hook2, ... |
| MCP Servers | N | server1, server2, ... |

**Total artifacts**: {total}
```
