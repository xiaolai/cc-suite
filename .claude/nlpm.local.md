---
# NLPM Configuration
strictness: strict
score_threshold: 80
rule_overrides:
  R31: { threshold: 900 }   # Stop hook intentionally permits up to 15min for the opt-in stop-review-gate Codex review; other cc-suite hooks (SessionStart/SessionEnd) remain at 5s
  R51:
    enabled: true
    vocabulary_skill: skills/cc-suite/vocabulary/
---

# NLPM Settings

When scoring NL artifacts in this project, use **strict** strictness.
Flag artifacts scoring below **80/100** for improvement.

> The former R01 meta-usage and R51 self-reference overrides were removed
> after nlpm 1.1.3 absorbed both as the rubric's own mention-versus-use
> exclusions (scoring skill, dated 2026-08-01) — the audit-family commands'
> quoted term lists and the vocabulary skill's declaration tables are now
> exempt by the rubric itself, not by project config.
