#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

import { readHookInput } from "./lib/hook-input.mjs";
import { verifyJobProcess } from "./lib/job-control.mjs";
import { terminateProcessTree, waitForExit } from "./lib/process.mjs";
import {
  isActiveJob,
  loadState,
  resolveStateFile,
  updateState,
} from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

export const SESSION_ID_ENV = "CODEX_TOOLKIT_SESSION_ID";
const PLUGIN_DATA_ENV = "CLAUDE_PLUGIN_DATA";

// SessionEnd runs on the user's exit path, so the whole confirmation budget is
// bounded and shared across jobs rather than paid per job.
const TERM_CONFIRM_MS = 1500;
const KILL_CONFIRM_MS = 500;

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function appendEnvVar(name, value) {
  if (!process.env.CLAUDE_ENV_FILE || value == null || value === "") return;
  fs.appendFileSync(
    process.env.CLAUDE_ENV_FILE,
    `export ${name}=${shellEscape(value)}\n`,
    "utf8"
  );
}

function cleanupSessionJobs(cwd, sessionId) {
  if (!cwd || !sessionId) return;

  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const stateFile = resolveStateFile(workspaceRoot);
  if (!fs.existsSync(stateFile)) return;

  const sessionJobs = loadState(workspaceRoot).jobs.filter(
    (j) => j.sessionId === sessionId
  );
  if (sessionJobs.length === 0) return;

  // Phase 1 — signal, off the lock. Only drop records for jobs confirmed dead;
  // anything merely signalled, unverifiable, or unsignallable is retained and
  // marked so a surviving process never becomes invisible.
  const removableIds = new Set();
  const retainedNotes = new Map();
  const signalled = new Map(); // jobId → pid awaiting exit confirmation

  for (const job of sessionJobs) {
    if (!isActiveJob(job)) {
      // A job cancelled without a confirmed exit may still have a live process.
      // Dropping its record (and pruning its log) is exactly the disappearance
      // this function exists to prevent, so re-check before removing it.
      if (job.terminationConfirmed === false) {
        const identity = verifyJobProcess(job);
        if (identity.state === "gone" || identity.state === "recycled") {
          removableIds.add(job.id);
        }
        continue;
      }
      removableIds.add(job.id);
      continue;
    }
    const identity = verifyJobProcess(job);
    switch (identity.state) {
      case "gone":
      case "recycled":
        // The original process is confirmed dead (a recycled PID belongs to
        // someone else and must never be signalled).
        removableIds.add(job.id);
        break;
      case "no-pid":
        retainedNotes.set(
          job.id,
          "Session ended; no recorded PID, so the job process could not be terminated."
        );
        break;
      case "unverifiable":
        retainedNotes.set(
          job.id,
          "Session ended; the job predates process-identity tracking, so it was not signalled and may still be running."
        );
        break;
      case "ours":
        try {
          const outcome = terminateProcessTree(identity.pid, { signal: "SIGTERM" });
          if (outcome.attempted && !outcome.delivered) removableIds.add(job.id);
          else signalled.set(job.id, identity.pid);
        } catch {
          retainedNotes.set(
            job.id,
            "Session ended; terminating the job process failed, so it may still be running."
          );
        }
        break;
    }
  }

  // Phase 2 — confirm exit within one shared budget, escalating once. A job is
  // only reported cancelled after its process is observed gone.
  if (signalled.size > 0) {
    let alive = waitForExit([...signalled.values()], TERM_CONFIRM_MS);
    if (alive.size > 0) {
      for (const [jobId, pid] of signalled) {
        if (!alive.has(pid)) continue;
        // Re-prove identity before escalating: the PID could have been recycled
        // between the last poll and now, and SIGKILL is unsurvivable.
        const job = sessionJobs.find((j) => j.id === jobId);
        if (job && verifyJobProcess(job).state !== "ours") {
          alive.delete(pid);
          continue;
        }
        try {
          terminateProcessTree(pid, { signal: "SIGKILL" });
        } catch {}
      }
      alive = waitForExit([...alive], KILL_CONFIRM_MS);
    }
    for (const [jobId, pid] of signalled) {
      if (alive.has(pid)) {
        retainedNotes.set(
          jobId,
          "Session ended; SIGTERM and SIGKILL were delivered but the process had not exited yet."
        );
      } else {
        removableIds.add(jobId);
      }
    }
  }

  if (removableIds.size === 0 && retainedNotes.size === 0) return;

  // Phase 3 — apply against the CURRENT state under the state lock. Signalling
  // and waiting took real time; a worker may have started or finished since the
  // snapshot, and its transition must not be clobbered by a stale write.
  const timestamp = new Date().toISOString();
  updateState(workspaceRoot, (state) => {
    state.jobs = state.jobs
      .filter((j) => !(removableIds.has(j.id) && j.sessionId === sessionId))
      .map((j) =>
        retainedNotes.has(j.id) && j.sessionId === sessionId && isActiveJob(j)
          ? {
              ...j,
              status: "cancelled",
              errorMessage: retainedNotes.get(j.id),
              updatedAt: timestamp,
            }
          : j
      );
  });
}

// Does .mcp.json carry a `codex-cli` key at all? Deliberately shallow: which
// shapes are cc-suite's own dead registration is decided in ONE place,
// scripts/lib/codex_mcp_entry.py, which prune_codex_mcp.sh consults. A second
// copy of that predicate here is how the two drift apart.
function hasCodexCliEntry(mcpPath) {
  try {
    const data = JSON.parse(fs.readFileSync(mcpPath, "utf8"));
    return Boolean(data?.mcpServers && typeof data.mcpServers === "object"
      && "codex-cli" in data.mcpServers);
  } catch {
    return false; // missing or invalid JSON — prune_codex_mcp.sh leaves it alone too
  }
}

// Remove the dead `codex-cli` registration an older cc-suite (≤2.0.1) wrote
// into .mcp.json. `codex mcp-server` no longer exists, so Claude Code reports a
// failed MCP connection every session until it is gone. Self-heal on
// SessionStart, then surface a one-line systemMessage via JSON stdout (the
// documented SessionStart channel) because the removal only reaches Claude Code
// on its next session.
// Returns a message for the caller to surface, or null. It does NOT write stdout:
// SessionStart's JSON contract is ONE object, and two self-heals firing in the
// same session would otherwise emit two.
function pruneDeadCodexCliRegistration(cwd) {
  if (!cwd) return null;
  // Registration lives at the workspace root; a SessionStart from a repository
  // subdirectory would otherwise silently miss it (job cleanup already
  // resolves the root, so this kept the two paths inconsistent).
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const mcpPath = path.join(workspaceRoot, ".mcp.json");
  if (!fs.existsSync(mcpPath) || !hasCodexCliEntry(mcpPath)) return null;

  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return null;
  const scriptPath = path.join(pluginRoot, "scripts", "prune_codex_mcp.sh");
  if (!fs.existsSync(scriptPath)) return null;

  spawnSync("bash", [scriptPath], {
    cwd: workspaceRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  // Announce only what actually happened: the script preserves a `codex-cli`
  // entry cc-suite did not write, and an exit status alone cannot tell that
  // apart from a removal. Re-read instead of trusting it.
  const removed = !fs.existsSync(mcpPath) || !hasCodexCliEntry(mcpPath);
  return removed
    ? "cc-suite: removed the dead codex-cli MCP registration from .mcp.json (`codex mcp-server` no longer exists in Codex CLI). Restart Claude Code to clear the failed MCP connection."
    : null;
}

// Re-point `.claude/skills/cc-suite` when it names an older plugin version.
//
// The link carries the version-stamped cache path, so EVERY plugin update makes
// it stale in every project, and once that version is pruned from the cache the
// link dangles and cc-suite's skills stop resolving — silently, and for Codex and
// agy too, which reach them through .agents/skills. /cc-suite:sweep can repair a
// whole machine, but nothing re-points a project until someone runs a command
// there, which is why one machine had 25 stale links and 7 dangling ones.
//
// Ownership is the same test the sweep applies: only a symlink that points into
// the plugin cache at a cc-suite skills tree. A link at a development checkout is
// deliberate and left alone; a real directory is someone's content.
function repointStaleSkillsLink(cwd) {
  if (!cwd) return null;
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return null;
  const wanted = path.join(pluginRoot, "skills", "cc-suite");
  if (!fs.existsSync(wanted)) return null;

  const link = path.join(resolveWorkspaceRoot(cwd), ".claude/skills/cc-suite");
  let current;
  try {
    if (!fs.lstatSync(link).isSymbolicLink()) return null; // authored directory
    current = fs.readlinkSync(link);
  } catch {
    return null; // absent — creating one is /cc-suite:init's job
  }
  if (current === wanted) return null;

  const cacheMarker = `${path.sep}plugins${path.sep}cache${path.sep}`;
  const looksLikeSkillsTree = current.endsWith(
    `${path.sep}skills${path.sep}cc-suite`
  );
  if (!current.includes(cacheMarker) || !looksLikeSkillsTree) return null;

  // rename(2) over the link itself: no window where the bridge is absent, and
  // (unlike `ln -sf` on macOS) the new link can never be created INSIDE the
  // directory the old one resolves to. Mirrors bridge_skills.sh.
  const tmp = `${link}.cc-suite-repoint-${process.pid}`;
  try {
    fs.symlinkSync(wanted, tmp);
    fs.renameSync(tmp, link);
  } catch {
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* nothing to clean up */
    }
    return null; // read-only checkout or a race — the sweep still reports it
  }
  return (
    "cc-suite: re-pointed .claude/skills/cc-suite at this plugin version " +
    "(it named an older one, which stops cc-suite's skills resolving once that " +
    "version leaves the cache)."
  );
}

function handleSessionStart(input) {
  appendEnvVar(SESSION_ID_ENV, input.session_id);
  appendEnvVar(PLUGIN_DATA_ENV, process.env[PLUGIN_DATA_ENV]);
  const cwd = input.cwd || process.cwd();
  // SessionStart JSON output schema: ONE object, whose `systemMessage` surfaces
  // in the Claude Code transcript. See https://code.claude.com/docs/en/hooks.md
  const messages = [
    pruneDeadCodexCliRegistration(cwd),
    repointStaleSkillsLink(cwd),
  ].filter(Boolean);
  if (messages.length > 0) {
    process.stdout.write(
      JSON.stringify({ systemMessage: messages.join(" ") }) + "\n"
    );
  }
}

function handleSessionEnd(input) {
  const cwd = input.cwd || process.cwd();
  cleanupSessionJobs(cwd, input.session_id || process.env[SESSION_ID_ENV]);
}

function main() {
  const input = readHookInput();
  const eventName = process.argv[2] ?? input.hook_event_name ?? "";

  if (eventName === "SessionStart") {
    handleSessionStart(input);
    return;
  }

  if (eventName === "SessionEnd") {
    handleSessionEnd(input);
  }
}

try {
  main();
} catch (error) {
  // Fail loud but readable: this runs on the user's session-start/end path, so
  // an unreadable state file (EACCES, EIO) should report one line and a
  // non-zero status rather than a raw stack trace in the transcript.
  process.stderr.write(
    `cc-suite session hook failed: ${error?.message || error}\n`
  );
  process.exitCode = 1;
}
