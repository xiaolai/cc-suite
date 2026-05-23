#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

import { terminateProcessTree } from "./lib/process.mjs";
import { loadState, resolveStateFile, saveState } from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

export const SESSION_ID_ENV = "CODEX_TOOLKIT_SESSION_ID";
const PLUGIN_DATA_ENV = "CLAUDE_PLUGIN_DATA";

function readHookInput() {
  const raw = fs.readFileSync(0, "utf8").trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

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

  const state = loadState(workspaceRoot);
  const sessionJobs = state.jobs.filter((j) => j.sessionId === sessionId);
  if (sessionJobs.length === 0) return;

  // Kill any still-running jobs for this session
  for (const job of sessionJobs) {
    if (job.status !== "queued" && job.status !== "running") continue;
    try {
      terminateProcessTree(job.pid ?? Number.NaN);
    } catch {
      // Ignore teardown failures during session shutdown
    }
  }

  // Remove session jobs from state
  saveState(workspaceRoot, {
    ...state,
    jobs: state.jobs.filter((j) => j.sessionId !== sessionId),
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
  const mcpPath = path.join(cwd, ".mcp.json");
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
    cwd,
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

main();
