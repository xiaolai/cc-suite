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
search for in *other* artifacts, and they appear inside backticks:

```
- **Ambiguous quantifiers**: Flag uses of `some`, `few`, `several`, `various` ... without concrete criteria
```

Penalizing these would mean cc-suite could never document vague-language
detection at all. Do not apply R01 to a flagged word when it appears inside
backticks within a list of terms the artifact is instructing a reader to detect.
Ordinary prose use of the same words is still penalized normally.

## Self-reference exemption (R51)

`skills/cc-suite/vocabulary/SKILL.md` is the file that *declares* the enforced
deprecation pairs. Its "Enforced deprecation pairs" table must name `pillar`,
`sub-agent`, and `freshen` literally in order to deprecate them. R51 is
mechanical and flags every occurrence regardless of context, so the registry's
own file would otherwise be penalized for doing its job — the same carve-out
NLPM applies to its own rules file quoting bad examples.

This exemption covers `skills/cc-suite/vocabulary/` only. Every other path in
the `internal` scope is scored normally.
