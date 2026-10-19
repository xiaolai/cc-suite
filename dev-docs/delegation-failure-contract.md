# Terminal-failure contract for Claude-backed delegation

This file is the **authoring source** for the `## Failure Handling` section that
appears in every skill which delegates through `claude_code` /
`claude_code_reply`, or through an advisor's `*_consult` tool.

Seven skills carry it: `claude-plan`, `claude-review`, `audit`, `verify`,
`audit-fix`, `claude-debug`, `claude-implement`.

The text is **embedded verbatim** in each `SKILL.md` rather than referenced from
them. That is deliberate. A skill is a prompt the model reads as one piece, and
these instructions are needed at precisely the moment something has already gone
wrong — making the model go read another file at that point adds a step that can
itself fail, and in a Codex or Antigravity session the plugin root is not even
guaranteed to resolve. Duplication is the cheaper risk, so the copies are kept
honest mechanically instead: `tests/delegation-failure.test.mjs` asserts every
one of the seven contains the block below byte-for-byte, and fails if a copy
drifts or a new delegating skill omits it.

To change the contract, edit the block below and re-run the test; it will name
every file that no longer matches.

---

## Failure Handling

A Claude-backed call that does not return a usable result is **terminal for this
skill**. Stop and report; do not improvise a way to keep going.

This covers every non-success outcome: a runtime or transport error, a timeout,
a rate limit, an empty or truncated result, and a result that does not match the
shape this skill asked for. Absence of an error is not success — a call that
returns nothing has failed, however it exited.

**Never report a failed call as a result.** It is not `CLEAN`, not "no findings",
not a completed verification, not an empty plan. A verification that did not run
is `UNVERIFIED`, and saying so is the entire value of the step.

**Do not recover on your own initiative.** Unless the user asks for it: do not
retry the call, do not open a replacement session, do not switch to another
Claude execution path (a different MCP tool, a different skill, a direct
invocation), and do not fall back to doing the work yourself in place of the
delegate. A failed `claude_code_reply` in particular must not silently become a
new `claude_code` session — that discards the conversation the reply was meant
to continue, and the original work may still be running.

**Preserve the session.** Report any `session_id` the call returned, even on
failure, so the user can resume that exact session rather than start over.

**Say what may still be running.** A timeout or transport error does not
establish that the work on the other side stopped. Say so explicitly, so the
user does not start a second attempt that overlaps the first.

Then stop according to what the call could have changed:

| Call class | On failure |
|---|---|
| Read-only (`claude-plan`, `claude-review`, `audit`, `verify`, advisor `*_consult`) | Report the operation as blocked, with the error and any `session_id`. Nothing was changed. |
| Write-capable (`claude-debug`, `claude-implement`) | Stop before any further delegation and state explicitly whether partial workspace changes may exist — the delegate may have written files before failing. Recommend the user inspect `git status` / `git diff`. |
| Cycle (`audit-fix`) | Stop the current cycle. Retain the existing findings and their fix status; do not discard them and do not mark unattempted findings as resolved. Report which finding the cycle stopped on. |

