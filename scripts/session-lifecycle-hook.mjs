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

function isLegacyNpmCodexRegistration(entry) {
  return (
    entry &&
    typeof entry === "object" &&
    entry.command === "npx" &&
    Array.isArray(entry.args) &&
    entry.args.some(
      (arg) => typeof arg === "string" && arg.includes("codex-mcp-server")
    )
  );
}

// Detect a stale codex-cli registration written by an older cc-suite (≤0.2.12)
// and migrate it via mcp_codex.sh. The migration takes effect on the next
// session — surface a one-line systemMessage via JSON stdout (the documented
// SessionStart channel) so the user knows to restart.
function migrateStaleCodexCliRegistration(cwd) {
  if (!cwd) return;
  // Registration lives at the workspace root; a SessionStart from a repository
  // subdirectory would otherwise silently miss it (job cleanup already
  // resolves the root, so this kept the two paths inconsistent).
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const mcpPath = path.join(workspaceRoot, ".mcp.json");
  if (!fs.existsSync(mcpPath)) return;

  let data;
  try {
    data = JSON.parse(fs.readFileSync(mcpPath, "utf8"));
  } catch {
    return; // invalid JSON — leave it alone
  }
  const entry = data?.mcpServers?.["codex-cli"];
  if (!isLegacyNpmCodexRegistration(entry)) return;

  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return;
  const scriptPath = path.join(pluginRoot, "scripts", "mcp_codex.sh");
  if (!fs.existsSync(scriptPath)) return;

  const result = spawnSync("bash", [scriptPath], {
    cwd: workspaceRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status === 0) {
    // SessionStart JSON output schema: `systemMessage` surfaces in the
    // Claude Code transcript. See https://code.claude.com/docs/en/hooks.md
    process.stdout.write(
      JSON.stringify({
        systemMessage:
          "cc-suite: migrated stale Codex MCP registration in .mcp.json — restart Claude Code to load the new server.",
      }) + "\n"
    );
  }
}

function handleSessionStart(input) {
  appendEnvVar(SESSION_ID_ENV, input.session_id);
  appendEnvVar(PLUGIN_DATA_ENV, process.env[PLUGIN_DATA_ENV]);
  migrateStaleCodexCliRegistration(input.cwd || process.cwd());
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
