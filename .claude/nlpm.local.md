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

When linting NL artifacts in this project, use **strict** strictness.
Flag artifacts scoring below **80/100** for improvement.
