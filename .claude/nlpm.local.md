---
# NLPM Configuration
strictness: strict
score_threshold: 80
rule_overrides:
  R31: { threshold: 900 }   # Stop hook intentionally permits up to 15min for the opt-in stop-review-gate Codex review; other cc-suite hooks (SessionStart/SessionEnd) remain at 5s
  R01:
    exempt_quoted_term_lists: true   # see "Meta-usage exemption" below
  R51:
    enabled: true
    vocabulary_skill: skills/cc-suite/vocabulary/
    exempt_paths:
      - skills/cc-suite/vocabulary/   # see "Self-reference exemption" below
---

# NLPM Settings

When linting NL artifacts in this project, use **strict** strictness.
Flag artifacts scoring below **80/100** for improvement.

## Meta-usage exemption (R01)

The audit-family commands (`audit-agent`, `audit-command`, `audit-nlp`,
`audit-plugin`, `audit-rules`) name vague quantifiers as **data**, not as
instructions — they are the literal strings the embedded Codex prompt is told to
search for in *other* artifacts:

```
- **Ambiguous quantifiers**: Flag uses of `some`, `few`, `several`, `various` ... without concrete criteria
```

Do not count a vague term when it is presented as a literal token and the
containing clause explicitly instructs the reader or a tool to detect, flag,
reject, replace, avoid, or report that term. **Backtick formatting alone does
not qualify** — a term still modifying an action, criterion, or requirement is
counted even when backticked (`` handle errors `properly` `` is still a
violation). Ordinary prose use is penalized normally.

## Self-reference exemption (R51)

`skills/cc-suite/vocabulary/SKILL.md` and `registry.yaml` *declare* the enforced
deprecation pairs, so they must name `pillar`, `sub-agent`, and `freshen`
literally in order to deprecate them.

Do not count a deprecated term when it occurs in the declaration that registers
it or maps it to its replacement — the registry tables and `deprecated:` lists.
This covers only the declaration term fields, **not** surrounding prose:
deprecated terms used in ordinary sentences inside `skills/cc-suite/vocabulary/`
are still counted, and every other path in the `internal` scope is scored
normally.

> Both exemptions restate the general mention-versus-use principle proposed
> upstream for nlpm's rubric. Once the installed nlpm version carries that
> principle natively, these two override entries become redundant and can be
> dropped; the R31 and R51-enable entries above remain project-specific.
