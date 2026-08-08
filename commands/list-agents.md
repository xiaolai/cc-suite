---
description: List every cc-suite advisor agent registered in this project — name, consult tool, model, tool scope, and one-line description.
---

# CC-Suite List Agents

Show the user every advisor agent declared in `.cc-suite/agents/`, with the information they'd need to know which one to consult.

## Workflow

### Step 1: Check that the directory exists

```bash
ls .cc-suite/agents/ 2>/dev/null
```

If `.cc-suite/agents/` doesn't exist or contains no `.md` files, tell the user:

```
No advisor agents in this project.

To add one, run `/cc-suite:add-agent <preset>` — available presets:
- north_star_advisor — project's overarching priorities
- clarity_reviewer — readability over correctness
- simplicity_advocate — smallest complete solution
- security_skeptic — adversarial reviewer
- deletion_advocate — finds removable code
- documentation_critic — judges doc honesty + audience fit

Or `/cc-suite:add-agent --custom` to write one from scratch.
```

Stop here.

### Step 2: Parse each agent file

For each `.cc-suite/agents/*.md`, extract from frontmatter:

- `name` (or filename stem if not declared)
- `description`
- `tool_name` (or `<name>_consult` if not declared)
- `model` (or "default" if not declared)
- `allowed_tools` (or default `[Read, Grep, Glob]`)
- `cwd` (or "." if not declared)
- `max_turns`, `max_budget_usd`

### Step 3: Render the report

```markdown
## Project advisors (N total)

| Agent | Consult tool | Model | Scope | Description |
|---|---|---|---|---|
| `<name>` | `mcp__<name>__<tool_name>` | <model> | <cwd> | <description> |
| ... | ... | ... | ... | ... |

### Details

#### <name>

- **Tools**: <allowed_tools>
- **Max turns**: <max_turns>
- **Budget cap**: $<max_budget_usd> per consultation
- **Timeline**: `.cc-suite/agents/<name>/timeline/` (gitignored by default)
- **File**: `.cc-suite/agents/<name>.md`

(Repeat per agent.)

### Status

- Bridge script: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py` — run after editing any file above
- Registrations live in: `.mcp.json` (Claude side), `.codex/config.toml` (Codex side), and the generated `.agents/mcp_config.json` projection for agy
- Restart Claude Code if you just added or removed an agent
- Run `/cc-suite:bridge-mcp` after adding or editing an agent if agy should see it
```

### Step 4: Sanity-check registration

Verify each declared agent actually appears in `.mcp.json`:

```bash
python3 -c "
import json, pathlib
mcp = json.loads(pathlib.Path('.mcp.json').read_text())
agents = set()
for k, v in mcp.get('mcpServers', {}).items():
    if isinstance(v, dict) and v.get('_cc_suite_agent'):
        agents.add(k)
print('\n'.join(sorted(agents)))
" 2>/dev/null
```

If any declared agent is missing from `.mcp.json`, append a warning at the end:

```
! <name> declared in .cc-suite/agents/ but not registered in .mcp.json — run /cc-suite:repair
```
