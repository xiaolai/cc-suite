---
name: vocabulary
description: "Use when writing, reviewing, or naming any cc-suite artifact — pick the canonical noun or verb from this registry rather than coining a synonym. Loaded by NLPM's scorer and checker when R51 is enabled in .claude/nlpm.local.md."
version: 0.1.0
---

# cc-suite Domain Vocabulary

> The canonical noun-and-verb set for cc-suite. Every artifact name, prose description, and rule wording should draw from this registry. Drift between canonical terms and declared deprecated synonyms is flagged by `/nlpm:check` and penalized by `/nlpm:score` when R51 is enabled.
>
> **Status:** seeded by `/nlpm:vocab-init` on 2026-05-26 and pruned during the initial migration pass. Only deprecation pairs that can be cleanly enforced (no false positives in the current corpus) are in `registry.yaml`. Other observed drift is documented below as **convention-only** with the rationale for non-enforcement.

---

## Scopes

cc-suite has a single scope. Unlike NLPM (internal + auditor), cc-suite's artifacts all describe one system — the bridge between Claude Code, Codex CLI, and Gemini CLI.

| Scope | Paths | Description |
|-------|-------|-------------|
| `internal` | `commands/`, `skills/cc-suite/`, `templates/agents/`, `AGENTS.md` | The cc-suite bridge subsystem itself. |

## Enforced deprecation pairs (R51 will flag these)

These are clean drifts: the canonical term has fully replaced the deprecated one in the corpus, and the deprecated term has no remaining legitimate uses.

| Canonical | Deprecated synonym | Status |
|-----------|--------------------|--------|
| `dimension` | `pillar` | Fully migrated (Mar 2026). All 5 audit-family commands now use `Dimension N:` headings and `(N dimensions)` phrasing. |
| `subagent` | `sub-agent` | Fully migrated. The hyphenated form was a typo accident in agent-design SKILL.md and audit-agent.md. |
| `refresh` | `freshen` | Fully migrated. `freshen-aware` / `freshen semantics` in AGENTS.md rewritten to `refresh-aware` / `refresh semantics`. |

## Canonical-only verbs (no deprecation; just the canonical form)

Used to establish the cc-suite verb vocabulary so new artifacts pick from this set rather than coining synonyms. R51 doesn't penalize anything here because no observed drift exists.

| Canonical | Definition |
|-----------|------------|
| `audit` | Structured multi-dimension code/artifact scan with severity table (Codex-delegated). |
| `bridge` | Umbrella verb for making one tool's config visible to another. |
| `update` | User-side coupled re-render after `claude plugin update cc-suite` (slash command). |
| `init` | First-time project setup of all cc-suite bridge artifacts. |
| `check` | Lightweight prerequisite / connectivity probe. |
| `consult` | Invoke a cc-suite advisor and receive its judgment. |
| `delegate` | Forward a task to Claude Code via `mcp__claude-code__claude_code`. |
| `fix` | Code-level remediation of a specific reported defect (distinct from `repair`). |
| `repair` | Non-interactive re-run of all bridge / registration scripts (distinct from `fix`). |
| `verify` | Confirm a prior code-fix outcome via Claude MCP. |
| `register` | Persist an MCP server entry into `.mcp.json` or `.codex/config.toml`. |
| `expose` | Symlink-based sub-operation of `bridge` for cc-suite plugin skills. |
| `mirror` | One-directional copy sub-operation of `bridge` for hooks and MCP. |
| `setup` | Higher-level user activity composed of init + configure + verify. |
| `review` | Send a plan or PR to Codex for architectural review (distinct from `consult`). |
| `cancel` `continue` `implement` `plan` `analyze` `result` `status` `add` `remove` `list` `preflight` `unbridge` | Single-command verbs; one canonical, no competing synonyms observed. |

## Canonical-only nouns

| Canonical | Definition |
|-----------|------------|
| `advisor` | A project-scoped value-over-rules persona declared in `.cc-suite/agents/`, backed by `claude-octopus` as a separately-configured MCP server. |
| `bridge` | The cc-suite-managed subsystem that wires Claude/Codex/Gemini together. |
| `finding` | A single defect surfaced by an audit/review — file:line, severity, recommendation. Use in structured audit output (column headers, "Top Findings" sections, per-finding iteration in audit-fix/verify). |
| `sentinel block` | The cc-suite-owned section in `.codex/config.toml` or `.gitignore`, delimited by sentinel comments. |
| `thread` | The Codex execution-continuation handle (the `threadId` MCP parameter). |
| `registration` | The persisted MCP server entry produced by `bridge`. |
| `preset` | A starter advisor agent file shipped under `templates/agents/`. |
| `pin` | The version string for `claude-octopus` in `scripts/lib/claude-octopus-pin.txt`. |
| `timeline` | The per-advisor persistent consultation history at `.cc-suite/agents/<name>/timeline/`. |
| `artifact` | A file cc-suite owns — command, skill, agent, hook, manifest, config. |
| `script` | An executable under `scripts/` — bash, python, or mjs. |

### Role-noun suffixes for advisor preset names (intentional sub-variants)

These are **not drift** — each suffix encodes the persona's stance.

| Suffix | Stance | Example preset |
|--------|--------|----------------|
| `_advisor` | General-purpose value advisor; broad-scope judgment. | `north_star_advisor` |
| `_reviewer` | Reviews finished work against a single quality dimension. | `clarity_reviewer` |
| `_critic` | Judges the output of an upstream process (typically docs). | `documentation_critic` |
| `_advocate` | Argues for one specific action over alternatives. | `deletion_advocate`, `simplicity_advocate` |
| `_skeptic` | Adversarial reviewer; assumes hostile inputs / worst case. | `security_skeptic` |

When introducing a new preset, pick the suffix that best matches its stance. Default to `_advisor` when none fit.

## Why some pairs are convention-only (not enforced by R51)

The `/nlpm:vocab-drift` scan surfaced several drift candidates that look like clean canonical/deprecated pairs but turn out to be **polysemous** in cc-suite. R51 is mechanical — it flags every occurrence of a deprecated term regardless of context — so declaring these would generate false-positive penalties on legitimate uses. They are conventions, not rules:

| Concept pair | Why we don't enforce |
|--------------|----------------------|
| `finding` ← `issue` | `finding` is canonical for audit-output rows (column headers, `Top Findings` sections, per-finding iteration in `audit-fix.md` / `verify.md`). But `issue` legitimately means a different thing elsewhere: infrastructure problem in `doctor.md` ("Found N issues. Fix them?"), implementation hiccup in `implement.md` ("Issues encountered"), code-quality category in audit prose ("minor clarity issues"). A blanket deprecation would mis-rename all three contexts. **Convention**: structured rows say `Finding`; everything else stays `issue`. |
| `advisor` ← `agent` | `advisor` is canonical for cc-suite personas in prose. But `agent` is unavoidable in file paths (`.cc-suite/agents/`, `templates/agents/`), command names (`add-agent`, `remove-agent`, `list-agents`) — chosen to match Claude Code's `.claude/agents/` convention — and refers to Claude Code's native subagent concept in design discussions. **Convention**: speak about "advisors" in prose; keep the file/dir/command layout using `agent`. |
| `thread` ← `session` | `thread` is canonical for the Codex execution-continuation handle. `session` appears in `continue.md`'s description as user-facing language ("Continue a previous Codex session"). **Convention**: prefer `thread` in technical contexts; tolerate `session` in user-facing descriptions. |
| `delegate` ← `ask` / `send` | `delegate` is canonical in skill bodies. `ask` and `send` appear in `description:` frontmatter openings of the claude-* skills because they're more natural English for a one-line summary. **Convention**: skill body uses `delegate`; frontmatter description allows either. |
| `preset` ← `template` | `preset` is the user-facing concept. `template` is the directory name (`templates/agents/`) and appears in `add-agent.md` frontmatter where it accurately describes what gets copied. **Convention**: speak about "presets" in prose; the on-disk word is `template`. |
| `verify` ← `check` | `verify` is canonical for code-fix-outcome confirmation. `check` covers infrastructure probes (`Step 2: Run additional deep checks` in `doctor.md`). **Convention**: don't conflate. |

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
4. To deprecate a synonym, add it to the canonical term's `deprecated:` list in `registry.yaml` AND update the "Enforced deprecation pairs" table above. Before doing this, run `grep -r "<deprecated>"` and confirm the term has no legitimate alternate meanings — if it does, document the pair in "Why some pairs are convention-only" instead.

## Adopting R51

To turn on vocabulary drift detection on this project, add to `.claude/nlpm.local.md`:

```yaml
rule_overrides:
  R51:
    enabled: true
    vocabulary_skill: skills/cc-suite/vocabulary/
```

The pruned registry should produce zero R51 findings on the current corpus.

## See also

- The corpus extractor: `${NLPM_ROOT}/analysis/scripts/extract-vocabulary.py`
- The six design principles: `${NLPM_ROOT}/analysis/vocabulary-design-principles.md`
- Run `/nlpm:vocab-drift` periodically to surface new candidate pairs as the corpus grows.
