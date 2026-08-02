---
description: Create a new cc-suite advisor agent — a project-scoped value-over-rules persona registered as an MCP server in both .mcp.json and .codex/config.toml. Optional preset arg copies a curated template.
argument-hint: "[preset-name | --custom]"
---

# CC-Suite Add Agent

Create a new advisor agent. Advisors are not subagents that *do* work — they are personas that *judge* work. The `agent-design` skill explains the philosophy; this command runs the mechanical workflow.

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Load the design skill

Before doing anything else, load and read `${CLAUDE_PLUGIN_ROOT}/skills/cc-suite/agent-design/SKILL.md`. Every decision below is informed by it.

### Step 2: Decide preset vs custom

List the available presets:

```bash
ls "${CLAUDE_PLUGIN_ROOT}/templates/agents/"
```

Parse `$ARGUMENTS`:

| Input | Action |
|-------|--------|
| (empty) | Show the preset list and ask the user to pick one or choose "custom" |
| `<preset-name>` (e.g. `north_star_advisor`) | Use that preset |
| `--custom` | Skip presets, go straight to custom flow |

If using a preset, copy it to `.cc-suite/agents/<name>.md`:

```bash
mkdir -p .cc-suite/agents
cp "${CLAUDE_PLUGIN_ROOT}/templates/agents/<preset-name>.md" ".cc-suite/agents/<preset-name>.md"
```

If the file already exists, ask the user whether to overwrite, edit, or cancel.

### Step 3: Tailor the preset (if used)

Open the copied file. Tell the user: "Edit the system prompt to reflect *this project's* values, not the generic preset. The preset is a starting point — narrow it to your codebase's actual priorities."

Offer to make common adjustments without re-asking:

```
AskUserQuestion:
  question: "Any quick adjustments before saving?"
  header: "Tailor"
  multiSelect: true
  options:
    - label: "Scope to subdirectory (set cwd)"
      description: "Restrict the advisor's filesystem view to a subdir like docs/ or src/"
    - label: "Change model"
      description: "Switch between opus / sonnet / haiku"
    - label: "Tighten budget"
      description: "Lower max_budget_usd or max_turns"
    - label: "Skip — use preset as-is"
      description: "Save and bridge immediately"
```

Apply each chosen adjustment by editing the file's frontmatter.

### Step 4: Custom agent (only if `--custom` or user chose it)

Ask the user, in one combined prompt, for:

1. **Name** (snake_case or kebab-case, will be the MCP server name)
2. **One-line description** (caller-facing)
3. **The values this advisor holds** (free-form; this becomes the system prompt body)

Then suggest defaults based on the skill's guidance:

```
AskUserQuestion:
  question: "Model?"
  header: "Model"
  options:
    - label: "sonnet (Recommended)"
      description: "Default. Good judgement, much cheaper than opus."
    - label: "opus"
      description: "Use only when the value system demands heavy reasoning."
    - label: "haiku"
      description: "Only for mechanical-but-restricted advisors. Rare."
```

```
AskUserQuestion:
  question: "Tool access?"
  header: "Tools"
  options:
    - label: "Read-only (Recommended)"
      description: "Read, Grep, Glob — the default. Advisors advise, they don't act."
    - label: "Read + Bash"
      description: "Only if the advisor needs to run checks that file reading can't capture."
    - label: "Open it up"
      description: "Custom tool list (you'll specify next)."
```

Write the resulting agent file to `.cc-suite/agents/<name>.md` using the frontmatter + body format documented in the skill.

### Step 5: Bridge the agent into MCP registrations

Run the bridge script:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

Expect output like:

```
✓ bridged N/N advisor(s) into .mcp.json + .codex/config.toml
    advisor: <name>  → tool: mcp__<name>__<tool_name>
```

If the script reports a conflict (a non-cc-suite MCP server already uses that name), tell the user to rename the agent or remove the conflicting entry, then re-run.

### Step 6: Confirm and report

Show the user:

```markdown
## Agent created: <name>

- **File**: `.cc-suite/agents/<name>.md`
- **Consult tool**: `mcp__<name>__<tool_name>`
- **Model**: <model>
- **Allowed tools**: <list>
- **Timeline**: `.cc-suite/agents/<name>/timeline/` (gitignored by default)

### Next steps

- Edit `.cc-suite/agents/<name>.md` to refine the system prompt — the value
  system is the load-bearing part. Re-run `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py` after edits.
- **Restart Claude Code** so the MCP loader picks up the new server.
- After restart, invoke as: `Use the mcp__<name>__<tool_name> tool to ask...`
- Codex picks up `.codex/config.toml` changes on next invocation — no restart needed.
```
