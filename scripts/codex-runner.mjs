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
import { extractErrorEvent, resolveFailureMessage } from "./lib/codex-errors.mjs";

const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes
const HEARTBEAT_MS = 30 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;

// Job id this process has registered but not yet finalized (or handed off to a
// detached worker). main()'s rejection handler marks it failed so a crash can
// never leave a foreground job recorded as running forever.
let activeJobId = null;

// A value-taking flag must be followed by a real value. "" is the background
// argv convention for "unset" and keeps its historical skip-the-flag behavior;
// another option in value position used to be consumed as the value (e.g.
// `--model --effort high` set model to "--effort") and now fails loudly.
function flagValue(value, flag) {
  if (value.startsWith("--")) {
    process.stderr.write(`Error: ${flag} requires a value, got '${value}'\n`);
    process.exit(1);
  }
  return value;
}

const KNOWN_FLAGS = new Set([
  "--kind", "--model", "--effort", "--sandbox", "--resume", "--timeout-ms",
  "--background", "--session-id", "--summary",
]);

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

  // Every token before `--` must be a known flag (or a flag value): unknown
  // options, stray positionals, missing flag values, and malformed values all
  // fail loudly pre-spawn instead of being silently dropped.
  let i = 2;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--") {
      args.prompt = argv.slice(i + 1).join(" ");
      break;
    }
    if (arg === "--background") {
      args.background = true;
      i += 1;
      continue;
    }
    if (!KNOWN_FLAGS.has(arg)) {
      process.stderr.write(
        arg.startsWith("--")
          ? `Error: unknown option '${arg}'\n`
          : `Error: unexpected argument '${arg}' — the prompt must follow '--'\n`
      );
      process.exit(1);
    }
    if (i + 1 >= argv.length) {
      process.stderr.write(`Error: ${arg} requires a value\n`);
      process.exit(1);
    }
    const raw = argv[i + 1];
    i += 2;
    if (raw === "") continue; // background "" placeholder — flag stays unset
    const value = flagValue(raw, arg);
    switch (arg) {
      case "--kind": args.kind = value; break;
      case "--model": args.model = value; break;
      case "--effort": args.effort = value; break;
      case "--sandbox": args.sandbox = value; break;
      case "--resume": args.resume = value; break;
      case "--session-id": args.sessionId = value; break;
      case "--summary": args.summary = value; break;
      case "--timeout-ms": {
        const n = Number(value);
        if (!Number.isFinite(n) || n <= 0) {
          process.stderr.write(`Error: --timeout-ms requires a positive number of milliseconds, got '${value}'\n`);
          process.exit(1);
        }
        args.timeoutMs = n;
        break;
      }
    }
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
    let errorEvent = null; // highest-ranked error seen on the JSONL stream
    let settled = false;
    let timedOut = false;

    // stdio[0] = "ignore" tells Node to open /dev/null and attach it to the
    // child's fd 0 — equivalent to running `codex exec ... < /dev/null` from a
    // shell. Required because `codex exec` can hang on stdin in background /
    // hook contexts that lack a controlling TTY. Do not change to "pipe" or
    // "inherit" without preserving an explicit /dev/null on stdin.
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
      // Terminal failures arrive here, not on stderr. Keep the most
      // authoritative one; ties go to the most recent event.
      const failure = extractErrorEvent(line);
      if (failure && (!errorEvent || failure.rank >= errorEvent.rank)) {
        errorEvent = failure;
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
        finish({
          status: "failed",
          errorMessage: resolveFailureMessage({
            event: errorEvent,
            stderr: stderrTail,
            code,
            signal,
          }),
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
  activeJobId = jobId;
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
  activeJobId = null; // job state and result are fully persisted

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
  activeJobId = jobId;
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

  // The worker records the running transition itself (with its own pid), so a
  // fast worker completion can never be overwritten with `running` here.
  child.on("error", (err) => {
    appendLog(logFile, `Background spawn error: ${err.message}`);
    upsertJob(cwd, {
      id: jobId,
      status: "failed",
      errorMessage: `Failed to start background worker: ${err.message}`,
      completedAt: new Date().toISOString(),
    });
  });

  child.unref();
  activeJobId = null; // the job now belongs to the detached worker

  const output = { jobId, status: "queued", message: `Job ${jobId} started in background.` };
  process.stdout.write(JSON.stringify(output) + "\n");
}

async function runBackgroundWorker(cwd, args, jobId) {
  const logFile = resolveJobLogFile(cwd, jobId);
  upsertJob(cwd, {
    id: jobId,
    status: "running",
    pid: process.pid,
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
  });
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

main().catch((error) => {
  const message = error?.message || String(error);
  // A worker crash finalizes the job named by its environment; a foreground or
  // spawn-parent crash finalizes whatever job this process registered but had
  // not yet brought to a terminal state.
  const jobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID || activeJobId || null;
  if (jobId) {
    try {
      upsertJob(resolveWorkspaceRoot(process.cwd()), {
        id: jobId,
        status: "failed",
        errorMessage: message,
        completedAt: new Date().toISOString(),
      });
    } catch {
      // State unreachable — the structured output below is the only signal.
    }
  }
  process.stdout.write(JSON.stringify({
    jobId,
    status: "failed",
    error: message,
  }) + "\n");
  process.stderr.write(`Error: ${message}\n`);
  process.exitCode = 1;
});
