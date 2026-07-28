---
name: init
description: Initialize cc-suite for the current project — sets up the AGENTS.md bridge, registers Codex, Claude, and Antigravity MCP surfaces, and generates a .cc-suite.md config
---

# CC-Suite Init

Set up cc-suite for the current project. This command leaves the project with **every bridge artifact in place** — anything `/cc-suite:repair` would re-create is created here first. The sub-routines, in order:

1. **Project config** — generates `.cc-suite.md` with your preferred audit settings
2. **Bridge init** — creates `AGENTS.md`, `CLAUDE.md` (`@AGENTS.md`), `.codex/config.toml`, and the `.gitignore` block
3. **Skills bridge** — exposes cc-suite's plugin skills via `.claude/skills/cc-suite` and `.agents/skills`
4. **MCP registration** — adds the `codex-cli` MCP server to `.mcp.json` and mirrors project MCP servers into `.codex/config.toml` and `.agents/mcp_config.json`
5. **Claude MCP registration** — adds the `claude-code` MCP server (claude-octopus) to `.codex/config.toml`
6. **Hooks bridge** — mirrors `.claude/settings.json` hooks into `.codex/hooks.json` (no-op if there are no hooks)
7. **Advisor agents bridge** — registers any declared `.cc-suite/agents/*.md` in Claude's `.mcp.json` and Codex's `.codex/config.toml`; the agy projection is refreshed by the MCP bridge (no-op if there are no agents)

## Workflow

### Step 1: Check for existing config

Check if `.cc-suite.md` already exists in the current working directory.

If it exists, read it and ask:

```
AskUserQuestion:
  question: "A .cc-suite.md already exists. What would you like to do?"
  header: "Config"
  options:
    - label: "Add missing sections (Recommended)"
      description: "Non-destructively top up the config with any new cc-suite-managed sections (e.g. Enabled Tools), preserving your existing settings"
    - label: "Show current config"
      description: "Display the current settings"
    - label: "Regenerate"
      description: "Replace with a fresh config — asks the questions again and discards customizations"
    - label: "Cancel"
      description: "Keep the current config as-is"
```

If "Add missing sections" → run the migration and report what it added, then STOP (do not re-run the interactive setup):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/migrate_config.py"
```

If the script exits non-zero, report the error instead of claiming the migration succeeded.

If "Show current config" → display the file contents and STOP.
If "Cancel" → STOP.
If "Regenerate" → continue to Step 2.

### Step 2: Gather project context

Detect the project's technology stack automatically:

1. Check for language/framework markers:
   - `package.json` → Node.js/JavaScript/TypeScript
   - `requirements.txt` / `pyproject.toml` / `setup.py` → Python
   - `Gemfile` → Ruby
   - `go.mod` → Go
   - `Cargo.toml` → Rust
   - `pom.xml` / `build.gradle` → Java
   - `*.csproj` / `*.sln` → C#/.NET

2. Check for test frameworks:
   - `jest.config.*` / `vitest.config.*` → JS test runner
   - `pytest.ini` / `conftest.py` → pytest
   - `spec/` directory → RSpec
   - `*_test.go` → Go tests

3. Check for project structure:
   - `src/` → source directory
   - `lib/` → library directory
   - `app/` → application directory (Rails, etc.)

### Step 2b: Run preflight to discover models

Run the preflight script to get the current model list:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-preflight.sh"
```

Parse the JSON output. Extract `default_model` (for older preflight output, fall back to the first entry in `models`) and the per-model `reasoning_efforts` from the `models_detail` entry matching `default_model` (top-level `reasoning_efforts` as fallback). Both feed Step 3: `default_model` labels the "Pin current model" option, and the effort list builds the effort options.

Do NOT write the resolved `default_model` slug into the config unless the user explicitly pins it in Step 3. The config records a **policy** (`latest`, or a deliberate pin) — not a snapshot. A snapshot goes stale as the Codex catalog moves; `latest` is re-resolved by preflight on every call and cannot go stale.

If preflight fails (status "error"), skip the model question in Step 3, write `latest` as the default model policy, and use the static effort fallback noted there.

### Step 3: Ask customization questions

Ask all questions at once:

```
AskUserQuestion:
  question: "What is the primary focus of audits for this project?"
  header: "Audit focus"
  options:
    - label: "Balanced (Recommended)"
      description: "Equal weight across all dimensions"
    - label: "Security-first"
      description: "Prioritize security, auth, data handling, and injection risks"
    - label: "Performance-first"
      description: "Prioritize performance, scalability, and efficiency"
    - label: "Quality-first"
      description: "Prioritize code quality, maintainability, and test coverage"
```

```
AskUserQuestion:
  question: "Default audit depth?"
  header: "Audit type"
  options:
    - label: "Mini (5 dimensions) (Recommended)"
      description: "Fast — logic, duplication, dead code, refactoring, shortcuts"
    - label: "Full (9 dimensions)"
      description: "Thorough — adds security, performance, compliance, deps, docs"
```

**Model policy question** (skip when preflight failed — write `latest` without asking):

```
AskUserQuestion:
  question: "Which Codex model should this project's commands default to?"
  header: "Model"
  options:
    - label: "Track latest (Recommended)"
      description: "Always follow the newest general-purpose model in the Codex catalog — currently {default_model}. Re-resolved on every call, never goes stale."
    - label: "Pin {default_model}"
      description: "Write this exact model into the config. Stays fixed until you edit .cc-suite.md — reproducible, but stops tracking the catalog."
```

**Effort question** — build the options from the `reasoning_efforts` list of the `models_detail` entry matching `default_model`; fall back to the top-level `reasoning_efforts` array for older preflight output that has no per-model metadata. Order the supported levels as `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra` (present entries only). Mark `high` as "(Recommended)" when available, otherwise the highest available level. If more than four levels are available, offer the window of four consecutive levels starting two below the recommendation in that ordered list (clamp the window to the list ends) — the user can type any other supported level via "Other". Use these descriptions where the level is offered:

| Level | Description |
|-------|-------------|
| `minimal` / `low` | Fast, mechanical checks only |
| `medium` | Balanced speed and depth |
| `high` | Thorough analysis, catches subtle issues |
| `xhigh` / `max` / `ultra` | Extended reasoning for the hardest audits |

If preflight failed — or it succeeded but both the per-model list and the top-level `reasoning_efforts` array are empty — fall back to the static options `high (Recommended)` / `medium` / `low`.

### Step 4: Generate config file

Write `.cc-suite.md` to the project root with the gathered information:

````markdown
# CC-Suite Configuration

Project-specific settings for cc-suite commands.
Generated by `/init`. Edit freely — all fields are optional.

## Project

- **Stack**: {detected stack, e.g. "TypeScript, React, Node.js"}
- **Test command**: {detected test command, e.g. "npm test", "pytest", "bundle exec rspec"}
- **Source directories**: {detected dirs, e.g. "src/, lib/"}

## Defaults

These override the built-in defaults for all commands in this project.
Remove a line to fall back to the built-in default.
`latest` is a policy, not a model name: Codex-delegating commands resolve it to
the newest general-purpose Codex model via preflight. Replace it with a concrete
slug (any entry from `/cc-suite:codex-preflight`'s model list) only to pin —
pins stop tracking the catalog.

- **Default model**: {"latest", or the pinned slug if the user chose to pin}
- **Default effort**: {chosen effort}
- **Default audit type**: {chosen audit type, "mini" or "full"}
- **Default sandbox**: workspace-write

## Audit Focus

{chosen focus, e.g. "balanced"}

Additional instructions appended to every audit's developer-instructions:

```text
(Insert the focus-specific instructions listed in the "Focus-specific instructions" section below)
```

## Skip Patterns

Files and directories to always skip during audits (glob patterns):

```text
node_modules/
dist/
build/
coverage/
*.min.js
*.bundle.js
*.lock
vendor/
.git/
```

## Project-Specific Instructions

Custom instructions appended to Codex's developer-instructions for every command.
Use this to tell Codex about your project's conventions, architecture, or constraints.

```text
{stack-derived instructions from the Step 2 detection — e.g. "This is a {detected stack} project. Follow existing patterns in {detected source dirs}." Leave the block empty when nothing was detected; never insert an example verbatim.}
```
````

**Focus-specific instructions** (for the "Additional instructions" section):

- **Balanced**: "Give equal attention to all audit dimensions."
- **Security-first**: "Prioritize security findings. Flag any auth bypass, injection, data exposure, or cryptographic weakness as Critical regardless of other severity heuristics."
- **Performance-first**: "Prioritize performance findings. Flag N+1 queries, O(n^2) algorithms, memory leaks, and blocking I/O as High regardless of other severity heuristics."
- **Quality-first**: "Prioritize code quality findings. Flag untested critical paths, high cyclomatic complexity, and DRY violations as High regardless of other severity heuristics."

### Step 5: Add managed sections, then confirm config

After writing the base `.cc-suite.md`, append the cc-suite-managed sections
(currently `## Enabled Tools`, the multi-tool bridge selector). This is the same
single-source migration the update/re-init paths use, so the section never drifts:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/migrate_config.py"
```

If the script exits non-zero, report the error and stop — later steps depend on a complete config.

Then display the generated `.cc-suite.md` settings.

---

### Step 5b: Choose which coding agents to bridge

Nobody needs every bridge. Detect what is actually installed, then let the user
confirm — a project that never runs Codex should not get a `.codex/` tree.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py" --detect
```

That prints one JSON object per tool with `id`, `display_name`, `installed`,
`china_tier`, and `china_note`. Build a single multi-select from it:

```
AskUserQuestion:
  question: "Which coding agents should cc-suite bridge in this project?"
  header: "Bridges"
  multiSelect: true
  options:  # one per tool, in registry order
    - label: "<display_name>"
      description: "<installed ? 'Installed' : 'Not found on PATH'> · <china_note>"
```

Rules for building the options:

- **Pre-select every tool whose `installed` is true.** That makes the common case
  a single Enter, while still letting someone tick a tool they are about to install.
- **Claude is always bridged** — it is the source of truth the others mirror from.
  List it as pre-selected; if the user unticks it, keep it on and say so.
- Surface `china_note` verbatim. Antigravity and Grok are VPN-only in mainland
  China, and that should be visible at the moment of choosing, not discovered later.
- Do not hide uninstalled tools. Someone bridging a repo before installing the CLI
  is a legitimate case; showing them as "Not found on PATH" is enough.

Record the answer:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py" --set-enabled <comma,separated,ids>
```

If the script exits non-zero, report the error and stop — every later step reads
this selection, so it must be recorded before continuing. To change it afterwards,
re-tick `## Enabled Tools` in `.cc-suite.md` and run `/cc-suite:bridge-tools`.

---

### Step 6: Bridge init

Run the bridge init script to create the single-source `AGENTS.md`. `CLAUDE.md` imports it; Codex and `agy` read it natively. It does not create new Gemini-era project files:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
```

If the script exits non-zero, report the error and stop. A successful run will print lines starting with `✓` or `·` for each artifact it sets up.

---

### Step 7: Expose plugin skills

Link cc-suite's plugin skills into `.claude/skills/cc-suite/` and create `.agents/skills → ../.claude/skills` so Codex can see the same skill set as Claude Code:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

If the script exits non-zero, report the error and stop.

---

### Step 8: Register Codex MCP server

**Skip the `mcp_codex.sh` registration below if the user did not select Codex in
Step 5b.** Say so in the summary rather than silently omitting it. `bridge_mcp.sh`
below also writes the Antigravity projection — run it if *either* Codex or
Antigravity was selected, and skip it only when neither was.

Add the `codex-cli` MCP server to `.mcp.json` so Claude can invoke Codex as an MCP tool:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
```

If the script exits non-zero, report the error and stop.

Then mirror the project MCP surface into `.codex/config.toml` and `.agents/mcp_config.json` so Codex and Antigravity can see it (`bridge_mcp.sh` intentionally excludes the `codex-cli` entry itself — Codex must not register itself as its own MCP server):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

If the script exits non-zero, report the error and stop.

---

### Step 9: Register Claude MCP server

**Skip if Codex was not selected** — this writes into `.codex/config.toml`, which
only exists when Codex is bridged.

Add the `claude-code` MCP server (claude-octopus) to `.codex/config.toml` so Codex can invoke Claude as an MCP tool:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
```

If the script exits non-zero, report the error and stop.

---

### Step 10: Bridge hooks

**Skip if Codex was not selected** — the only target is `.codex/hooks.json`.

Mirror `.claude/settings.json` hooks into `.codex/hooks.json` so Codex runs the same lifecycle hooks Claude Code does. This is a no-op when the project has no hooks yet — safe to run unconditionally:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

If the script exits non-zero, report the error and stop.

---

### Step 11: Bridge advisor agents

Register any cc-suite advisor agents declared in `.cc-suite/agents/*.md` as MCP servers in `.mcp.json` and `.codex/config.toml`. `bridge_mcp.sh` then includes the same source entries in the generated `.agents/mcp_config.json` for agy. No-op when the project has no agents yet — safe to run unconditionally:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

If the script reports any conflicts (user-managed entries with the same name as a declared agent), surface them and continue. Conflicts don't block init — they just leave the conflicting agent unregistered until the user resolves the naming. Any other non-zero exit → report the error and stop.

---

### Step 11b: Refresh projections for the final MCP surface

Two things are still pending at this point: advisor registration in Step 11 may have changed `.mcp.json` *after* the Antigravity projection was generated in Step 8, and the extra tools selected in Step 5b (Grok Build, opencode, Qwen Code, Kimi CLI) have not been bridged at all — `--set-enabled` only records the selection. Re-run both bridges so every projection reflects the final MCP surface. Both are idempotent; run them even when Step 11 was a no-op:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"      # skip when neither Codex nor Antigravity was selected in Step 5b
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py"  # no-op when no extra tools are enabled
```

If either script exits non-zero, report the error and stop.

---

### Step 12: Final summary

Display a combined status report:

```markdown
## cc-suite initialized

### Bridge artifacts

{output of scripts/status.sh — show the Bridge artifacts section only}

### Bridged agents

{one line per tool the user selected in Step 5b}
{then, if any were skipped: "Not bridged: <list> — re-tick in `.cc-suite.md` and run `/cc-suite:bridge-tools` to add them later."}

### MCP delegation

{include only the lines for tools that were actually bridged}

- **Claude → Codex**: `.mcp.json` has `codex-cli` registered ✓
- **Codex → Claude**: `.codex/config.toml` has `claude-code` registered ✓
- **agy → Claude**: `.agents/mcp_config.json` has the generated `claude-code` entry when the agy projection is available ✓

### Project config

- `.cc-suite.md` created with {chosen settings}

### Next steps

- Run `/cc-suite:status` to see full bridge health
- Edit `AGENTS.md` to add project-specific conventions
- Commit `AGENTS.md`, `.cc-suite.md`, `.mcp.json` to share with your team

{include the next two only if Codex was bridged}

- Run `/audit` to test Codex delegation
- Have Codex call Claude with `$claude-review` or `$claude-plan`
```
