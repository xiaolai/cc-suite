---
name: implement
description: Send a plan to Codex MCP for full autonomous implementation — choose model, effort, and sandbox level
argument-hint: "<plan-file-or-inline-plan> [--background | --wait]"
---

# Codex Implement

Delegate an entire implementation plan to Codex MCP. Claude is the architect, Codex is the builder.

## Input

```text
$ARGUMENTS
```

## Workflow

### Step 0: Parse Execution Mode

Parse `$ARGUMENTS` for `--background` or `--wait` flags (remove the flag from remaining arguments):

| Flag | Mode |
|------|------|
| `--background` | Background — spawn detached Codex runner, return job ID |
| `--wait` | Foreground (explicit) — same as default |
| Neither | Foreground (default) — run inline, block until complete |

### Step 1: Resolve the plan

Determine the plan content from `$ARGUMENTS`:

| Input | Action |
|-------|--------|
| A file path (e.g. `plan.md`, `./docs/plan.txt`) | Read the file to get the plan |
| Inline text | Use the text directly as the plan |
| (empty) | Look for `PLAN.md` in cwd, then ask the user |

Read the plan content and display a brief summary to the user.

**Large plans**: If the plan exceeds 200 lines, warn the user that very large plans may exceed Codex's context window and suggest breaking it into phases.

### Step 2: Let user choose model and settings

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: first available from preflight
- **Recommended reasoning effort**: `medium`
- **Recommended sandbox level**: `workspace-write`
- **Include sandbox question**: Yes

### Step 3: Confirm and send to Codex

Show the final configuration:
- Plan: (summary)
- Working directory: {cwd}
- Model: {chosen_model}
- Reasoning effort: {chosen_effort}
- Sandbox: {chosen_sandbox}

If `--background` mode was selected, follow the **Background Execution** section in `commands/shared/codex-call.md`. Build the prompt as described below, then hand off to the background runner with `--kind implement`.

Follow `commands/shared/codex-call.md` for availability test, call pattern, and **Job Tracking**.

- **Command persona**: "You are an autonomous implementation agent. Execute plans completely."
- **Sandbox**: `{chosen_sandbox}`
- **Approval-policy**: `never`

> **Warning**: If the user selected `danger-full-access` sandbox, display a confirmation before proceeding: "You chose `danger-full-access` with `approval-policy: never` — Codex will have unrestricted read/write/execute access with no approval prompts. Continue?" Use `AskUserQuestion` with "Continue" and "Switch to workspace-write" options.

```
prompt: "Execute the following plan completely from start to finish in the current working directory.

IMPORTANT RULES:
- Implement EVERY step in the plan. Do not skip anything.
- Create all files, install all dependencies, write all code as specified.
- Run tests/builds if the plan includes them.
- If a step fails, debug and fix it before moving on.
- After completing all steps, run a final verification (build, test, lint). Run the project's test suite if detected (`npm test`, `cargo test`, `pytest`, `go test ./...`, etc.).
- Report a summary of: files created, files modified, commands run, and any issues encountered.

THE PLAN:
{plan_content}"
```

**IMPORTANT**: Wait for Codex to fully complete before proceeding.

### Step 4: Verify results

After Codex finishes:

1. Run `git status` to see all changes Codex made
2. Run `git diff --stat` to summarize the scope
3. If the project has tests, run them to verify correctness
4. Report the results to the user:

```markdown
## Codex Implementation Complete

**Model**: {chosen_model} | **Effort**: {chosen_effort} | **Sandbox**: {chosen_sandbox}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate)_

**Files created**:
- {file path (or "none")}

**Files modified**:
- {file path (or "none")}

**Commands run**:
- {command (or "none")}

### Verification
- Tests: PASS / FAIL / N/A
- Build: PASS / FAIL / N/A

### Issues
- {any issues or warnings}
```

### Step 5: Offer next steps

Ask the user what to do next:
- Review the changes in detail
- Commit the changes
- Run additional tests
- Revert if something went wrong (`git checkout .`)
  - **Warning**: `git checkout .` permanently discards ALL uncommitted changes. Consider `git stash` as a safer alternative.

### Fallback

If Codex is unavailable (availability test fails):

1. Inform the user: "Codex is not available."
2. Offer alternatives via `AskUserQuestion`:
   - **"Implement with Claude (Recommended)"** — Claude reads the plan and executes each step directly using Read, Edit, Write, and Bash tools
   - **"Check connectivity"** — Run `/preflight` to diagnose
   - **"Cancel"** — Stop and try again later
3. If "Implement with Claude": read the plan, break it into numbered steps, and execute each step sequentially — creating files, installing dependencies, running tests as specified. Report progress after each major step.
