---
name: remove-agent
description: Remove a cc-suite advisor agent — deletes the `.cc-suite/agents/<name>.md` file and re-runs the bridge to clean up its registrations and (optionally) its timeline.
argument-hint: "<agent-name>"
---

# CC-Suite Remove Agent

Delete an advisor agent from the project. The agent's MCP registrations and timeline data are removed; the agent file itself goes too.

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Resolve the target

Parse `$ARGUMENTS` as the agent name. If empty, list the agents (call `/cc-suite:list-agents` logic) and ask the user to pick one.

Verify the file exists:

```bash
ls ".cc-suite/agents/<name>.md" 2>/dev/null
```

If it doesn't exist, list what *does* exist:

```bash
ls .cc-suite/agents/*.md 2>/dev/null
```

and stop.

### Step 2: Confirm and ask about the timeline

```
AskUserQuestion:
  question: "Remove agent `<name>`? This deletes .cc-suite/agents/<name>.md and re-bridges. What about its timeline directory?"
  header: "Confirm"
  options:
    - label: "Remove agent + delete timeline (Recommended)"
      description: "Cleanest. The timeline contains the advisor's prior consultation history."
    - label: "Remove agent, keep timeline"
      description: "Preserves the history at .cc-suite/agents/<name>/timeline/ — useful if you might recreate the agent later."
    - label: "Cancel"
      description: "Do nothing."
```

If cancel: stop.

### Step 3: Delete the agent file

```bash
rm ".cc-suite/agents/<name>.md"
```

### Step 4: Delete the timeline directory (if requested)

```bash
rm -rf ".cc-suite/agents/<name>/"
```

(Note: only if the user chose the "delete timeline" option.)

### Step 5: Re-bridge

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

The script will detect the agent file is gone and remove the corresponding entries from both `.mcp.json` and `.codex/config.toml`.

### Step 6: Report

```markdown
## Agent removed: <name>

- Deleted `.cc-suite/agents/<name>.md`
- Deleted `.cc-suite/agents/<name>/` (if chosen)
- Cleaned up `.mcp.json` entry
- Cleaned up `.codex/config.toml` sentinel block

### Reminder

Restart Claude Code so the MCP loader drops the removed server. Codex sees the change on next invocation.
```
