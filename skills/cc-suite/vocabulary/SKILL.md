---
name: vocabulary
description: "Use when writing, reviewing, or naming any cc-suite artifact — pick the canonical noun or verb from this registry rather than coining a synonym. Loaded by NLPM's scorer and checker when R51 is enabled in .claude/nlpm.local.md."
version: 0.1.0
---

# cc-suite Domain Vocabulary

> The canonical noun-and-verb set for cc-suite. Every artifact name, prose description, and rule wording should draw from this registry. Synonyms are flagged by `/nlpm:check` and penalized by `/nlpm:score` when R51 is enabled.
>
> **Status:** seeded by `/nlpm:vocab-init` on 2026-05-26. Seeded with literary warrant from the corpus extractor plus high-confidence drift pairs from `/nlpm:vocab-drift`. R51 is OFF by default — see "Adopting R51" below.

---

## Scopes (P1 of vocabulary-design-principles.md)

cc-suite has a single scope. Unlike NLPM (which has both internal and auditor scopes), cc-suite's artifacts all describe one system — the bridge layer between Claude Code, Codex CLI, and Gemini CLI. There is no "auditor scope" because cc-suite delegates audit work to Codex via shared skills rather than running its own audit pipelines.

| Scope | Paths | Description |
|-------|-------|-------------|
| `internal` | `commands/`, `skills/cc-suite/`, `templates/agents/`, `AGENTS.md` | What cc-suite does to its own bridge and advisor artifacts. |

## Verbs (literary warrant from corpus)

Each canonical verb has a one-line scope note. The **deprecated synonyms** column lists terms that were observed in the corpus but should be replaced by the canonical when authoring new artifacts. An empty deprecated column means no drift is currently flagged — but new authors should still check `registry.yaml` for the latest list.

### internal scope

| Canonical verb | Frequency | Scope of action | Deprecated synonyms |
|----------------|-----------|-----------------|---------------------|
| `audit` | 9 | Structured multi-dimension code/artifact scan with severity table (Codex-delegated) | — |
| `bridge` | 3 | Umbrella verb for making one tool's config visible to another (write to `.mcp.json` + `.codex/config.toml`) | — |
| `refresh` | 3 | Re-pull external content (e.g. Claude Code conventions) and re-render anything derived from it | — |
| `init` | 1 (+ `initialize` 2) | First-time project setup of all cc-suite bridge artifacts | `initialize` (allow only in H1 headings) |
| `check` | 2 | Lightweight prerequisite / connectivity probe | — |
| `consult` | (body) | Invoke a cc-suite advisor agent via MCP and receive its judgment | `review` (when "review" means consulting an advisor; `review` stays canonical for Codex-delegated plan/PR analysis) |
| `delegate` | (frontmatter) | Forward a task to Claude Code via `mcp__claude-code__claude_code` | `ask`, `send` (allowed in frontmatter description openings only) |
| `fix` | 1 | Code-level remediation of a specific reported defect | — (distinct from `repair`, which means infrastructure recovery) |
| `repair` | 1 | Non-interactive re-run of all cc-suite bridge / registration scripts | — (distinct from `fix`) |
| `verify` | 1 | Confirm a prior code-fix outcome via Claude MCP | `check` (only when the operation is confirmation, not connectivity probing) |
| `update` | 1 | User-side coupled refresh after `claude plugin update cc-suite` | `freshen` (implementation-internal term; do not use in user-facing prose) |
| `register` | (body) | Persist an MCP server entry into `.mcp.json` or `.codex/config.toml` | — |
| `expose` | (body, "Expose skills") | Symlink-based sub-operation of `bridge` for cc-suite plugin skills | — |
| `mirror` | (body) | One-directional copy sub-operation of `bridge` for hooks and MCP | — |
| `setup` | 1 | Higher-level user activity composed of init + configure + verify; not interchangeable with `init` (which is one step of setup) | — |
| `add` / `remove` / `list` | 1 / 2 / 2 | CRUD verbs for the `.cc-suite/agents/` advisor registry | — |
| `cancel`, `continue`, `implement`, `plan`, `analyze`, `result`, `status`, `unbridge` | 1 each | Specific commands; no canonical-vs-synonym competition observed | — |
| `preflight` | 1 | Verify Codex connectivity and discover available models before delegation | — |
| `create` / `fetch` | 1 each | Description-only verbs, not yet competing | — |

`bridge`, `expose`, and `mirror` are intentionally three terms naming three distinct sub-operations within the bridge subsystem — they are NOT synonyms. `bridge` is the umbrella; `expose` covers skills (symlinks); `mirror` covers hooks and MCP (file copies). Authors should pick the specific verb when describing a single operation and the umbrella when describing the subsystem.

## Nouns (literary warrant from corpus)

### Artifact-class nouns

| Canonical | Frequency | Definition | Deprecated synonyms |
|-----------|-----------|------------|---------------------|
| `advisor` | (heading) | A project-scoped value-over-rules persona declared in `.cc-suite/agents/`, backed by `claude-octopus` as a separately-configured MCP server | `agent` (when referring to a cc-suite advisor; `agent` stays canonical for Claude Code's native subagent concept) |
| `subagent` | (body) | A Claude Code Task-tool spawned worker that executes focused work in isolated context | `sub-agent` (hyphenated form) |
| `bridge` | 10 | The cc-suite-managed subsystem that wires Claude/Codex/Gemini together via shared AGENTS.md, mirrored MCP servers, and exposed skills | — (used as both noun and verb; see verb table) |
| `finding` | 11 | A single defect surfaced by an audit/review — file:line, severity, recommendation | `issue` (when referring to a structured audit table row; `issue` stays canonical for user-facing prompts and GitHub issues) |
| `dimension` | 13 | A numbered axis the auditor scores artifacts against (e.g. "Dimension 1: Logic & Correctness") | `pillar` (used in the audit-family commands but should converge on `dimension` to match `audit.md`, the umbrella command) |
| `pillar` | 17 | (currently used in `audit-agent.md`, `audit-command.md`, `audit-skill.md`, `audit-rules.md`, `audit-plugin.md` — flagged for migration to `dimension`) | — |
| `sentinel block` | (body) | The cc-suite-owned section in `.codex/config.toml` or `.gitignore`, delimited by `# >>> cc-suite-... >>>` / `# <<< ... <<<` comments | bare `block` (too generic; reserve for `code block` / `review gate blocks`) |
| `thread` | (body) | The Codex execution-continuation handle (the `threadId` MCP parameter, displayed as "Thread ID" in command output) | `session` (in continue.md description; align on `thread` to match the actual parameter name) |
| `registration` | 6 | The persisted MCP server entry produced by `bridge`; lives in `.mcp.json` and `.codex/config.toml` | — |
| `preset` | (body) | A starter advisor agent file shipped under `templates/agents/` for users to copy and customize | `template` (when used in user-facing prose; `template` stays canonical for the directory name `templates/agents/`) |
| `pin` | (body) | The version string for `claude-octopus` in `scripts/lib/claude-octopus-pin.txt` that every bridge script reads | — |
| `timeline` | (body) | The per-advisor persistent consultation history at `.cc-suite/agents/<name>/timeline/` | — |
| `artifact` | (body) | A file cc-suite owns: command, skill, agent, hook, manifest, config | — |
| `script` | (body) | An executable under `scripts/`: bash, python, mjs | — |

### Role-nouns (advisor-preset filenames paired with their stance)

The persona suffixes are **intentional sub-variants** of `advisor`, not drift. Each suffix encodes the persona's stance:

| Role-noun suffix | Meaning | Example preset |
|------------------|---------|----------------|
| `_advisor` | General-purpose value advisor; offers judgement on broad scope | `north_star_advisor` |
| `_reviewer` | Reviews finished work against a single quality dimension | `clarity_reviewer` |
| `_critic` | Judges the output of an upstream process (typically docs) | `documentation_critic` |
| `_advocate` | Argues for one specific action over alternatives | `deletion_advocate`, `simplicity_advocate` |
| `_skeptic` | Adversarial reviewer; assumes hostile inputs / worst case | `security_skeptic` |

When introducing a new preset, pick the suffix that best matches its stance. If none fit, default to `_advisor`.

---

## How to extend

1. Re-run extraction:

   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT:-~/.claude/plugins/cache/xiaolai/nlpm/1.0.0}/analysis/scripts/extract-vocabulary.py \
     --root . \
     --scopes analysis/vocab-init-scopes.json \
     --out analysis/vocabulary-extract/
   ```

2. New terms appear in `analysis/vocabulary-extract/summary.md`.
3. Add a row to the matching table above (Verbs or Nouns, in the correct scope). Cite at least one file as evidence.
4. To deprecate a synonym, list it in the canonical term's "Deprecated synonyms" column AND add it to `registry.yaml`'s `deprecated:` list.

## Adopting R51

R51 is **off by default**. The registry is seeded and ready, but enabling it will produce penalty findings against the corpus until the deprecated terms are migrated. To turn on vocabulary drift detection on this project, add to `.claude/nlpm.local.md`:

```yaml
rule_overrides:
  R51:
    enabled: true
    vocabulary_skill: skills/cc-suite/vocabulary/
```

Without this opt-in, R51 contributes zero penalty regardless of artifact contents — but `/nlpm:check` will still report drift advisorily.

Recommended migration sequence before flipping the switch:

1. `issue` → `finding` in audit-fix.md, verify.md, audit table rows
2. `pillar` → `dimension` across the audit-family commands
3. `agent` → `advisor` in cc-suite-advisor contexts (rename `add-agent` / `remove-agent` / `list-agents` to `add-advisor` / etc. is optional but cleanest)
4. `sub-agent` → `subagent` in agent-design SKILL.md
5. Then enable R51 and re-score.

## See also

- The corpus extractor lives at `${NLPM_ROOT}/analysis/scripts/extract-vocabulary.py`
- The six design principles: `${NLPM_ROOT}/analysis/vocabulary-design-principles.md`
- The starting drift scan that informed this registry: run `/nlpm:vocab-drift` for an updated advisory list
