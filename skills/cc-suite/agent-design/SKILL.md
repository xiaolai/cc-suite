---
name: agent-design
description: Use when creating, editing, or reviewing a cc-suite advisor agent (a value-over-rules persona under `.cc-suite/agents/`). Covers system-prompt phrasing, model choice, tool restrictions, working-dir scoping, budget/turn limits, and the file format. Use proactively whenever the user asks to "add an agent", "make an advisor", "write a reviewer", or edits anything under `.cc-suite/agents/`.
---

# Designing cc-suite Advisor Agents

cc-suite advisor agents are project-scoped consultative personas backed by `claude-octopus`. Each lives at `.cc-suite/agents/<name>.md` and is registered as an MCP server in **both** `.mcp.json` (Claude side) and `.codex/config.toml` (Codex side) by `scripts/bridge_agents.py`. Either tool can call any agent via `mcp__<name>__<tool_name>`.

Advisors are not subagents that *do* work. They are advisors that *judge* work. Get this mental model right and the rest follows.

## When to make an advisor vs use the Task tool vs write a skill

- **Task tool / subagent**: needed when you want a subagent to *execute* a focused chunk of work in isolated context (research, refactor a file, run a probe). The subagent returns a result and disappears.
- **Skill**: knowledge or convention that any caller can load on demand. Static text. No model invocation.
- **Advisor agent**: needed when you want a *persistent persona with a stable point of view* that the main caller can consult repeatedly. Different system prompt, different tool restrictions, different model — and the advisor remembers past consultations via its timeline directory.

Rule of thumb: if you'd describe the thing as "a person you'd ask for an opinion," it's an advisor. If you'd describe it as "a job you'd hand off," it's a subagent. If it's "a rulebook," it's a skill.

## The file format

```markdown
---
name: <kebab_or_snake_case_name>          # required if filename ≠ desired name
description: |                             # multi-line block scalar — see below
  <one-line caller-facing summary>

  <example>
  Context: <when a caller would consult this advisor>
  user: "<the kind of question they'd ask>"
  assistant: "<how Claude/Codex would invoke the advisor — show the framing, not the answer>"
  </example>

  <example>
  Context: <a second, different scenario>
  user: "<another representative question>"
  assistant: "<another framing>"
  </example>
tool_name: <name>_consult                  # optional; default <name>_consult
model: opus | sonnet | haiku               # optional; default = caller's setting
allowed_tools: [Read, Grep, Glob]          # default for advisors
disallowed_tools: []                       # optional
permission_mode: default                   # default | acceptEdits | plan | dontAsk | auto | bypassPermissions
max_turns: 5                               # default 5 for advisors
max_budget_usd: 0.50                       # per-consultation cap
effort: high                               # low | medium | high | max
cwd: .                                     # relative to project root, default "."
additional_dirs: []                        # extra readable dirs
prompt_mode: append                        # append (default) or replace
---

# Body content — the system prompt

State the values, not the procedures. See the writing rules below.
```

The body becomes the `CLAUDE_APPEND_PROMPT` (default) or `CLAUDE_SYSTEM_PROMPT` (when `prompt_mode: replace`). Almost always use `append` — Claude Code's preset is useful, you're adding a perspective on top of it.

### Why `<example>` blocks in description matter

The `description` field becomes the MCP tool description that Claude and Codex see when deciding whether to consult this advisor. Two `<example>` blocks showing realistic call sites teach the *caller* (not the advisor itself) when this advisor is the right one to invoke. Without them, the caller has only a one-liner to go on and tends to either over-call or under-call the advisor.

Use a YAML literal block scalar (`description: |`) so newlines and `<example>` tags survive parsing. `bridge_agents.py` preserves the full multi-line value into `CLAUDE_DESCRIPTION` verbatim.

## Writing the prompt: values, not procedures

The point of an advisor is to bring a *value system* to the table that the caller doesn't have. If you write the prompt as a checklist, you've built a linter, not an advisor.

**Procedures (what to avoid):**
> Check that variables have descriptive names. Look for line length over 80 chars. Verify each function has a docstring. Flag any TODO comments.

**Values (what to write):**
> You hold readability above cleverness. When you read code, ask: would a maintainer six months from now know what this does without context? When the answer is no, name the specific reason — a misleading variable, a deeply nested clause, a comment that contradicts the code.

The difference: procedural prompts run the same way every time. Value prompts respond to *what the code actually shows*. The advisor will surface different concerns on different code, because the values reweight the same observations differently.

How to phrase values:

- **State the principle directly.** "You hold X above Y." Not "consider X." Strong stance produces useful judgement; hedged stance produces hedged advice.
- **Rank the values.** Two values can conflict; the prompt should tell the advisor which wins. "Simple > clever > short" — order matters.
- **Name what to ignore.** Advisors who try to cover everything become noise. "Ignore style and formatting" is liberating, not restrictive.
- **Demand specificity in output.** "Cite file:line. Name the value violated. Propose the smallest change." This pushes the advisor away from hand-waving.

## Model choice

- **opus** — for genuinely judgement-heavy advisors where the value system requires reading code carefully and reasoning about consequences. `north_star_advisor`, `security_skeptic`, `architecture_critic`. Worth the cost.
- **sonnet** — the default. Most advisors. `clarity_reviewer`, `simplicity_advocate`, `documentation_critic`. Good judgement, much cheaper.
- **haiku** — for narrow advisors where the judgement is mechanical-but-restricted: "look for X and report instances." `style_checker`, `link_validator`. Rarely needed — if the work is this mechanical, a skill or script is probably better than an advisor.

If you find yourself reaching for opus by default, ask: is the value system actually doing complex judgement, or am I just hoping a bigger model produces better output? Bigger model on a vague prompt produces verbose, hedged output. Smaller model on a sharp prompt produces sharp output.

## Tool restrictions: default to read-only

Advisors advise. They don't act. The default `allowed_tools: [Read, Grep, Glob]` is the right starting point for almost every advisor — they need to read the codebase to advise on it, but they should not write, edit, run shell commands, or fetch URLs.

When to open up:

- **Add `Bash`**: only when the advisor needs to run a check that file reading can't capture (e.g., a documentation advisor that needs to verify CI commands work). Even then, prefer letting the *caller* run the command and feed results to the advisor.
- **Add `WebFetch`** / `WebSearch`: rare. Most advisors should reason from the project's own code; web access invites consultation drift.
- **Add `Edit`/`Write`**: almost never. If an advisor needs to write, you've built a subagent, not an advisor. Use the Task tool path instead.

If you can't justify a tool's presence in one sentence, take it out.

## Working directory scoping

`cwd` defaults to project root. Override when an advisor should only see a subset:

```yaml
name: docs_advisor
cwd: docs
```

This advisor's `claude` subprocess sees `docs/` as its filesystem root. It physically cannot read code outside `docs/` unless `additional_dirs` opens specific paths. This is genuinely useful:

- Documentation advisors don't need to read code.
- Test-coverage advisors might be scoped to `tests/` + `src/` only.
- A frontend-focused reviewer can be scoped to `web/` to keep responses focused.

The advisor's `CLAUDE_TIMELINE_DIR` is **always** at `.cc-suite/agents/<name>/timeline/` regardless of `cwd` — that's per-agent persistent state, not the working scope.

## Budget and turns

- **max_turns**: default 5 for advisors. Advisors should answer in a few turns, not run extended conversations. If your advisor needs 20 turns, it's doing work, not advising.
- **max_budget_usd**: per-call cap. Stops a runaway. Default $0.50 for opus advisors, $0.20 for sonnet. Tighter than you think you need.

These aren't safety theater — they're a contract with the caller that consulting an advisor is *cheap*. If consultation is expensive, the caller stops consulting, and your advisor sits idle.

## Tool naming

`tool_name` controls the MCP-visible tool. Defaults to `<name>_consult`:

- agent `north_star_advisor` → tool `north_star_advisor_consult` → callable as `mcp__north_star_advisor__north_star_advisor_consult` (clunky)
- agent `north_star_advisor` with `tool_name: north_star_consult` → callable as `mcp__north_star_advisor__north_star_consult` (cleaner)

Pick `tool_name` so the callable form reads like an English action: `consult`, `check`, `review`, `audit`.

## Common mistakes

- **Procedure disguised as value.** "You value running every test before merging" is a procedure phrased as a value. Real value: "You value confidence over speed; flag merges where the evidence is thin."
- **Three advisors that all do the same thing.** If two advisors produce the same review on the same code, you have one advisor and a duplicate. Make sure each advisor has a *different* value system, not just a different name.
- **Asking for everything.** "Review for clarity, performance, security, style, and tests" produces noise. Each advisor should have one value system.
- **Bypassing the values.** Prompts that say "follow these steps:" hand the model a procedure. Values let the model produce judgement; procedures produce checklists.
- **Forgetting the timeline.** Each advisor remembers prior consultations in its `timeline/` directory. Use this — `_followup` tools let the caller continue a conversation. Don't design every advisor like it's stateless.

## Concrete examples

The plugin ships starter presets under `templates/agents/` — copy and edit, don't reinvent:

- `north_star_advisor` — project's overarching priorities
- `clarity_reviewer` — readability over correctness
- `simplicity_advocate` — smallest complete solution
- `security_skeptic` — adversarial reviewer
- `deletion_advocate` — finds removable code
- `documentation_critic` — judges doc honesty + audience fit

These are starting points. Edit the values to match the project, narrow the scope with `cwd`, tighten the tool list. The presets are well-formed but generic; the *value* of your project's advisors is in how they reflect *this project's* priorities.

## After editing an agent

Any edit to an agent file (creating, modifying, deleting) requires re-running the bridge. The first line resolves the plugin root in both hosts — Claude Code sets `CLAUDE_PLUGIN_ROOT`; a Codex session resolves it from the bridged skills symlink:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(readlink -f .claude/skills/cc-suite)")")}"
bash "${PLUGIN_ROOT}/scripts/init.sh"     # or
python3 "${PLUGIN_ROOT}/scripts/bridge_agents.py"
```

`/cc-suite:add-agent` and `/cc-suite:remove-agent` do this automatically. `/cc-suite:repair` and `/cc-suite:update` re-bridge as part of their normal flow.

For Claude to actually see the new MCP server, restart the Claude Code session (the MCP loader reads `.mcp.json` at startup, not on every prompt). Codex picks up `.codex/config.toml` changes per-invocation.

## Scope Note

This skill covers **cc-suite advisor agent design** — claude-octopus-backed MCP advisors declared in `.cc-suite/agents/`. It defines the file format, the values-not-procedures prompt convention, model and tool defaults, working-directory scoping, budget caps, and the per-agent timeline model.

It does **not** cover:

- **Claude Code's native subagent system** (Task tool, `.claude/agents/`) — a different mechanism with different semantics. Use those when you want to spawn a one-shot subagent in isolated context, not when you want a persistent consultative persona. See [`claude-architecture`](../../../../claude-architecture) for the native-agent surface.
- **Skill authoring** — for writing skills (knowledge that loads on demand, no model invocation), refer to `cc-suite/claude-code-conventions` and the `nlpm:conventions` family.
- **MCP server authoring from scratch** — `claude-octopus` is the MCP server; this skill describes how to *configure* it per advisor, not how to build a new MCP server.
- **The bridge mechanics** — how `bridge_agents.py` writes `.mcp.json` and `.codex/config.toml`. See `scripts/bridge_agents.py` itself, plus `commands/init.md` / `repair.md` / `update.md` for when the bridge runs.
