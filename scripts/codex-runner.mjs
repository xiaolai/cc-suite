#!/usr/bin/env node
// codex-runner.mjs — Run Codex tasks in foreground or background with job tracking.
//
// Usage:
//   node codex-runner.mjs --kind <kind> --model <model> --effort <effort> \
//     --sandbox <sandbox> [--resume <threadId>] [--timeout-ms <ms>] \
//     [--background] [--session-id <id>] [--summary <text>] \
//     -- <prompt>
//
// Runs the Codex CLI directly via `codex exec` (not the MCP bridge). The MCP
// bridge has no controllable timeout and hangs on long single responses; the
// CLI subprocess is killable, can be deadline-bounded, and streams JSONL events
// we tail into the job log as a heartbeat.
//
// In foreground mode, prints a JSON result to stdout and exits.
// In background mode, detaches and writes the result to the job file.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import {
  generateJobId,
  upsertJob,
  writeJobFile,
  resolveJobLogFile,
} from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes
const HEARTBEAT_MS = 30 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;

function parseArgs(argv) {
  const args = {
    kind: "job",
    model: null,
    effort: "medium",
    sandbox: "read-only",
    resume: null,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    background: false,
    sessionId: null,
    summary: null,
    prompt: null,
  };

  let i = 2;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--kind" && argv[i + 1]) { args.kind = argv[++i]; }
    else if (arg === "--model" && argv[i + 1]) { args.model = argv[++i]; }
    else if (arg === "--effort" && argv[i + 1]) { args.effort = argv[++i]; }
    else if (arg === "--sandbox" && argv[i + 1]) { args.sandbox = argv[++i]; }
    else if (arg === "--resume" && argv[i + 1]) { args.resume = argv[++i]; }
    else if (arg === "--timeout-ms" && argv[i + 1]) {
      const n = Number(argv[++i]);
      if (Number.isFinite(n) && n > 0) args.timeoutMs = n;
    }
    else if (arg === "--background") { args.background = true; }
    else if (arg === "--session-id" && argv[i + 1]) { args.sessionId = argv[++i]; }
    else if (arg === "--summary" && argv[i + 1]) { args.summary = argv[++i]; }
    else if (arg === "--") {
      args.prompt = argv.slice(i + 1).join(" ");
      break;
    }
    i++;
  }

  return args;
}

function appendLog(logFile, message) {
  const timestamp = new Date().toISOString();
  fs.appendFileSync(logFile, `[${timestamp}] ${message}\n`, "utf8");
}

// Build the `codex exec` argv. A fresh call takes -s/--sandbox; a resume call
// inherits the original session's sandbox and rejects -s, so it is omitted.
function buildCodexArgs(args, lastMessageFile) {
  const codexArgs = ["exec"];
  if (args.resume) {
    codexArgs.push("resume", args.resume);
  }
  if (args.model) codexArgs.push("--model", args.model);
  if (!args.resume) codexArgs.push("--sandbox", args.sandbox);
  codexArgs.push("--skip-git-repo-check");
  codexArgs.push("--json");
  codexArgs.push("-c", `model_reasoning_effort=${args.effort}`);
  codexArgs.push("-o", lastMessageFile);
  codexArgs.push(args.prompt);
  return codexArgs;
}

function extractThreadId(line) {
  // JSONL events carry the session UUID as "thread_id" (thread.started et al.).
  try {
    const evt = JSON.parse(line);
    if (evt && typeof evt.thread_id === "string") return evt.thread_id;
  } catch {
    // line isn't a complete JSON object — fall back to a tolerant regex scan
  }
  const m = line.match(/"thread_id"\s*:\s*"([0-9a-fA-F-]{16,})"/);
  return m ? m[1] : null;
}

function readLastMessage(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

// Run codex exec asynchronously: stream JSONL to the log (heartbeat), capture
// the thread id, and enforce a hard deadline by killing the child. Resolves
// with { status, rawOutput, threadId, errorMessage }.
function executeCodex(cwd, args, logFile) {
  return new Promise((resolve) => {
    const lastMessageFile = path.join(
      os.tmpdir(),
      `codex-last-${process.pid}-${Date.now()}.txt`
    );
    const codexArgs = buildCodexArgs(args, lastMessageFile);

    appendLog(logFile, `Exec: codex ${codexArgs.slice(0, -1).join(" ")} <prompt>`);
    appendLog(logFile, `Model: ${args.model}, Effort: ${args.effort}, Sandbox: ${args.resume ? "(inherited via resume)" : args.sandbox}`);
    appendLog(logFile, `Deadline: ${Math.round(args.timeoutMs / 1000)}s`);

    const startedAt = Date.now();
    let threadId = null;
    let stdoutBuf = "";
    let stderrTail = "";
    let settled = false;
    let timedOut = false;

    const child = spawn("codex", codexArgs, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env },
    });

    const heartbeat = setInterval(() => {
      const elapsed = Math.round((Date.now() - startedAt) / 1000);
      appendLog(logFile, `…still running (${elapsed}s elapsed)`);
    }, HEARTBEAT_MS);

    const deadline = setTimeout(() => {
      timedOut = true;
      appendLog(logFile, `Deadline exceeded (${Math.round(args.timeoutMs / 1000)}s) — terminating`);
      child.kill("SIGTERM");
      setTimeout(() => {
        if (!settled) child.kill("SIGKILL");
      }, SIGKILL_GRACE_MS);
    }, args.timeoutMs);

    function finish(result) {
      if (settled) return;
      settled = true;
      clearInterval(heartbeat);
      clearTimeout(deadline);
      try { fs.unlinkSync(lastMessageFile); } catch { /* ignore */ }
      resolve(result);
    }

    function processLine(line) {
      if (!line.trim()) return;
      fs.appendFileSync(logFile, line + "\n", "utf8");
      if (!threadId) {
        const found = extractThreadId(line);
        if (found) {
          threadId = found;
          appendLog(logFile, `Thread: ${threadId}`);
        }
      }
    }

    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      let nl;
      while ((nl = stdoutBuf.indexOf("\n")) !== -1) {
        processLine(stdoutBuf.slice(0, nl));
        stdoutBuf = stdoutBuf.slice(nl + 1);
      }
    });

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderrTail = (stderrTail + text).slice(-2000);
      fs.appendFileSync(logFile, text, "utf8");
    });

    child.on("error", (err) => {
      appendLog(logFile, `Spawn error: ${err.message}`);
      finish({ status: "failed", errorMessage: err.message, threadId, rawOutput: "" });
    });

    child.on("close", (code, signal) => {
      if (stdoutBuf.trim()) processLine(stdoutBuf); // flush a final unterminated line
      stdoutBuf = "";
      const rawOutput = readLastMessage(lastMessageFile);
      if (timedOut) {
        finish({
          status: "stalled",
          errorMessage: `Timed out after ${Math.round(args.timeoutMs / 1000)}s`,
          threadId,
          rawOutput,
        });
        return;
      }
      if (code !== 0) {
        const stderrMsg = stderrTail.trim();
        finish({
          status: "failed",
          errorMessage:
            code === null
              ? `signal ${signal}${stderrMsg ? `: ${stderrMsg}` : ""}`
              : stderrMsg || `exit ${code}`,
          threadId,
          rawOutput,
        });
        return;
      }
      appendLog(logFile, "Completed successfully");
      finish({ status: "completed", threadId, rawOutput });
    });
  });
}

async function runForeground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;
  const deadlineAt = new Date(Date.now() + args.timeoutMs).toISOString();

  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    status: "running",
    summary: args.summary || `${args.kind} task`,
    sessionId,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    deadlineAt,
    logFile,
  });

  appendLog(logFile, `Starting ${args.kind} task (foreground)`);

  const result = await executeCodex(cwd, args, logFile);

  upsertJob(cwd, {
    id: jobId,
    status: result.status,
    threadId: result.threadId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.threadId || null,
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });

  const output = {
    jobId,
    status: result.status,
    threadId: result.threadId || null,
    rawOutput: result.rawOutput || "",
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  };
  process.stdout.write(JSON.stringify(output) + "\n");
  if (result.status !== "completed") process.exitCode = 1;
}

function runBackground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;

  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    status: "queued",
    summary: args.summary || `${args.kind} task`,
    sessionId,
    logFile,
  });

  appendLog(logFile, `Queued ${args.kind} task (background)`);

  const childArgv = [
    fileURLToPath(import.meta.url),
    "--kind", args.kind,
    "--model", args.model || "",
    "--effort", args.effort,
    "--sandbox", args.sandbox,
    "--timeout-ms", String(args.timeoutMs),
    "--session-id", sessionId || "",
    "--summary", args.summary || "",
  ];
  if (args.resume) childArgv.push("--resume", args.resume);
  childArgv.push("--", args.prompt);

  const child = spawn(process.execPath, childArgv, {
    cwd,
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      CODEX_TOOLKIT_BACKGROUND_JOB_ID: jobId,
    },
  });

  upsertJob(cwd, {
    id: jobId,
    status: "running",
    pid: child.pid,
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
  });

  child.unref();

  const output = { jobId, status: "queued", message: `Job ${jobId} started in background.` };
  process.stdout.write(JSON.stringify(output) + "\n");
}

async function runBackgroundWorker(cwd, args, jobId) {
  const logFile = resolveJobLogFile(cwd, jobId);
  appendLog(logFile, "Background worker started");

  const result = await executeCodex(cwd, args, logFile);

  upsertJob(cwd, {
    id: jobId,
    status: result.status,
    threadId: result.threadId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.threadId || null,
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });
}

async function main() {
  const args = parseArgs(process.argv);

  if (!args.prompt) {
    process.stderr.write("Error: no prompt provided. Use -- <prompt>\n");
    process.exit(1);
  }

  const cwd = resolveWorkspaceRoot(process.cwd());

  // Detached background worker spawned by runBackground: do the actual work.
  const backgroundJobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID;
  if (backgroundJobId) {
    await runBackgroundWorker(cwd, args, backgroundJobId);
    return;
  }

  if (args.background) {
    runBackground(cwd, args);
  } else {
    await runForeground(cwd, args);
  }
}

main();
