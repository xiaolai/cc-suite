---
description: Sweep every project on this machine that cc-suite has bridged — report cross-repo leftovers, and repair the safe ones on request. Use when a cc-suite defect left something behind in many repos at once.
---

# CC-Suite Sweep

`/cc-suite:diagnose` and `/cc-suite:repair` fix the project they run in. This command works across every project on the machine, because cc-suite is commonly installed into dozens of repos at project scope, and a defect in what the bridge *wrote* leaves a copy in every one of them. The SessionStart self-heal only reaches a repo when a session actually opens there; this is how the rest get cleaned.

All discovery, classification, and repair live in `scripts/sweep.py`. This command is a thin wrapper — do not re-implement the checks in prose.

## The engine contract

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sweep.py" --json
```

Returns one JSON object:

- `plugin_version` — the version of the plugin doing the sweeping. Projects are repaired with **these** scripts, not with whatever version their install record names, which is the point: one up-to-date plugin cleans every repo.
- `projects{}` — keyed by absolute path. Each has `mcp_state` (`absent` / `dead_builtin` / `dead_legacy_npm` / `foreign` / `unparseable` / `no_file`), `agy_stale_mirror`, `agy_managed`, `recorded_version`, and `source` (`install-record` or `scan`).
- `stale_records[]` — recorded project paths that no longer exist.
- `notes[]` — discovery caveats, including the user-scope note below.
- `fixes{}` — present after `--fix`: per project, the commands run and whether it came out clean.

Exit code: 0 when no project needs action, 1 otherwise.

Flags: `--fix` applies repairs; `--scan DIR` (repeatable) also looks for bridged projects under `DIR`, `--depth N` controls how far it descends (default 3).

## What it repairs, and what it refuses

Repairs, because they are provably cc-suite's own and safe without the project's context:

- the dead `codex-cli` MCP registration in `.mcp.json` (`prune_codex_mcp.sh`)
- the same server left behind in a cc-suite-owned `.agents/mcp_config.json` (`bridge_mcp.sh`, run only in projects that actually have that stale mirror)

- a `.claude/skills/cc-suite` symlink still pointing at an older version's cache path (`bridge_skills.sh` re-points it). This one rots on **every** plugin update, because the link names the version-stamped cache directory — and once that version is pruned from the cache the link dangles and cc-suite's skills stop resolving entirely, for Codex and agy too, which reach them through `.agents/skills`. A symlink that does not name a cc-suite skills tree, and a real directory at that path, are someone else's and are left alone.

Both repairs run scripts that own more than the one file:

`bridge_mcp.sh` re-renders **both** projections it owns, so a project repaired that way also gets its `.codex/config.toml` sentinel block rewritten. The content is the project's existing MCP surface — but the block is re-emitted at the end of the file, so a tracked `config.toml` can show a one-time relocation diff. Say so when reporting, rather than letting the user find an unexplained diff in a repo they did not ask you to touch.

`bridge_skills.sh` re-points the symlink and then refreshes that project's `.gitignore` cc-suite block, so a tracked `.gitignore` can change too. It also refuses — non-zero, nothing touched — when `.agents/skills` is a real path or points somewhere cc-suite did not put it; report that project instead of retrying.

Refuses, and reports instead:

- a `codex-cli` entry cc-suite did not write — it is the user's own server
- an `.mcp.json` it cannot parse — a human decides what that file should say
- a user-managed `.agents/mcp_config.json` with no cc-suite provenance
- **version drift.** Re-rendering a project's bridge is `/cc-suite:update`'s job, in that project, where the user can see it. The sweep never runs a full repair across repos unattended.

## Workflow

### Step 1: Report first, always

Run the engine with no flags (or `--json`) and show the user the result. **Never start with `--fix`** — it writes to every affected repo, and the user has to see the list before that happens.

If a user-scope install is reported in `notes`, say so and offer `--scan`: projects bridged under a user-scope install leave no per-project record, so they are invisible until scanned. Suggest the directories the user actually keeps repos in.

### Step 2: Confirm before repairing

If any project needs action, use `AskUserQuestion` to confirm, naming the count: "Repair N project(s)?" Offer the option to review the list again. If the user declines, stop and leave the report.

### Step 3: Apply

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sweep.py" --fix
```

Report the engine's own per-project output — what was run and what came out clean. Do not summarize it away: a bulk change the user cannot see is a bulk change they cannot check.

### Step 4: Close honestly

- State how many projects were repaired and how many still need a human, with the reason for each.
- Tell the user to **restart any Claude Code session that was already open** in a repaired repo. MCP config is read at session start, so a running session keeps showing the old failed connection until it restarts.
- If anything was refused, give the exact per-project command to finish it (`/cc-suite:diagnose` in that repo).

## Notes

- Read-only by default, idempotent, and safe to re-run. Re-running after a fix reports zero action.
- Discovery reads `~/.claude/plugins/installed_plugins.json` (honoring `CLAUDE_CONFIG_DIR`). That file belongs to Claude Code, so the engine shape-checks it and degrades to "found nothing" with a note rather than failing.
