---
description: "Shared: resolve plugin root, validate manifest, discover all artifacts, build cross-reference map"
user-invocable: false
---
<!-- Shared partial: plugin artifact discovery for Claude Code plugin directories -->
<!-- Referenced by: audit-plugin. Do not use standalone. -->

## Plugin Discovery

### Resolve Plugin Root

Determine the plugin directory from `{plugin_dir}` (extracted from `$ARGUMENTS` by the calling command):

| Input | Resolution |
|-------|------------|
| (empty) | Use current working directory |
| Relative or absolute path | Use the given path |

**Validate**: Look for `.claude-plugin/plugin.json` in the resolved directory.

- If found → set `{plugin_root}` to that directory, read and parse `plugin.json`
- If NOT found → respond: "No `.claude-plugin/plugin.json` found in `{resolved_path}`. Not a Claude Code plugin directory." and STOP.

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
| Hooks | `hooks/hooks.json` | JSON array of hook objects |
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
