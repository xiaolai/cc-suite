#!/usr/bin/env node
// agy-runner.mjs — Run Antigravity CLI (`agy`) tasks in foreground or background
// with job tracking. Mirrors codex-runner.mjs so /cc-suite:status, /result and
// /cancel work identically across both backends.
//
// Usage:
//   node agy-runner.mjs --kind <kind> --model <model> --sandbox <sandbox> \
//     [--resume <conversationId>] [--timeout-ms <ms>] [--mode <mode>] \
//     [--add-dir <dir>]... [--background] [--session-id <id>] [--summary <text>] \
//     -- <prompt>
//
// ─── How this differs from codex-runner, and why ─────────────────────────────
//
// `agy` is a thinner CLI than `codex exec`. Three capabilities the Codex runner
// leans on do not exist, and each forces a workaround:
//
//   1. No `--json` event stream. Codex emits JSONL we tail as a heartbeat and
//      mine for the thread id. `agy -p` emits only the final prose answer on
//      stdout. So stdout IS the result — we accumulate it rather than reading a
//      side-channel file.
//
//   2. No `-o <file>` clean-answer channel. Same consequence as (1): rawOutput
//      is the captured stdout, trimmed.
//
//   3. No printed conversation id. Codex hands back `thread_id`; agy prints
//      nothing. But it does persist each conversation to
//      ~/.gemini/antigravity-cli/conversations/<uuid>.db, so we snapshot that
//      directory before the run and diff it after. See captureConversationId().
//      This is best-effort and inherently racy — two agy runs finishing
//      concurrently can each observe the other's new file. When the diff is
//      ambiguous we record null rather than guess wrong, which costs a resume
//      but never resumes the WRONG conversation.
//
// `agy` also has no reasoning-effort flag: effort is encoded in the model name
// ("Gemini 3.1 Pro (High)"). --effort is accepted and ignored, with a log line.

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

const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes — matches codex-runner
const HEARTBEAT_MS = 30 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;

// Where agy persists conversations. Overridable for tests.
const CONVERSATIONS_DIR =
  process.env.AGY_CONVERSATIONS_DIR ||
  path.join(os.homedir(), ".gemini", "antigravity-cli", "conversations");

function parseArgs(argv) {
  const args = {
    kind: "agy",
    model: null,
    effort: null,      // accepted for CLI parity; agy has no effort flag
    sandbox: "read-only",
    mode: null,        // agy --mode: accept-edits | plan
    addDirs: [],
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
    else if (arg === "--mode" && argv[i + 1]) { args.mode = argv[++i]; }
    else if (arg === "--add-dir" && argv[i + 1]) { args.addDirs.push(argv[++i]); }
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

// Snapshot the conversation .db filenames so a post-run diff reveals the id of
// the conversation this call created. Returns a Set of uuid strings.
function snapshotConversations() {
  try {
    return new Set(
      fs.readdirSync(CONVERSATIONS_DIR)
        .filter((f) => f.endsWith(".db"))
        .map((f) => f.slice(0, -3))
    );
  } catch {
    return new Set(); // dir may not exist before agy's first run
  }
}

// Diff against the pre-run snapshot. Exactly one new id → that's ours. Zero or
// more than one → ambiguous (concurrent agy runs); return null rather than
// attach the wrong conversation to this job.
function captureConversationId(before, logFile) {
  const after = snapshotConversations();
  const fresh = [...after].filter((id) => !before.has(id));
  if (fresh.length === 1) return fresh[0];
  if (fresh.length === 0) {
    appendLog(logFile, "Conversation id: none created (agy may have reused a conversation)");
  } else {
    appendLog(logFile, `Conversation id: ambiguous — ${fresh.length} new conversations appeared concurrently; not guessing`);
  }
  return null;
}

// Convert ms → a Go duration string, which is what --print-timeout wants.
function goDuration(ms) {
  return `${Math.max(1, Math.round(ms / 1000))}s`;
}

// Build the `agy` argv.
//
// Sandbox mapping (cc-suite vocabulary → agy flags). agy's --sandbox is a
// boolean ("terminal restrictions enabled"), not a level, so the three cc-suite
// levels collapse onto two agy switches:
//
//   read-only          → --sandbox                (restricted; no auto-approve)
//   workspace-write    → --mode accept-edits --dangerously-skip-permissions
//   danger-full-access → --dangerously-skip-permissions
//
// Anything that writes needs --dangerously-skip-permissions: headless `-p` mode
// has no TTY to answer a permission prompt, so without it the run would block
// until the deadline and be killed.
function buildAgyArgs(args) {
  const agyArgs = [];

  if (args.resume) agyArgs.push("--conversation", args.resume);
  if (args.model) agyArgs.push("--model", args.model);

  if (args.sandbox === "read-only") {
    agyArgs.push("--sandbox");
  } else if (args.sandbox === "workspace-write") {
    agyArgs.push("--mode", args.mode || "accept-edits");
    agyArgs.push("--dangerously-skip-permissions");
  } else if (args.sandbox === "danger-full-access") {
    agyArgs.push("--dangerously-skip-permissions");
  }

  // An explicit --mode overrides the sandbox-derived default.
  if (args.mode && args.sandbox !== "workspace-write") {
    agyArgs.push("--mode", args.mode);
  }

  for (const dir of args.addDirs) agyArgs.push("--add-dir", dir);

  // Let agy enforce the same deadline we do. Ours (SIGTERM) is the backstop for
  // the case where agy ignores its own timeout.
  agyArgs.push("--print-timeout", goDuration(args.timeoutMs));
  agyArgs.push("-p", args.prompt);

  return agyArgs;
}

// Run agy asynchronously: accumulate stdout (which IS the answer), heartbeat
// into the job log, and enforce a hard deadline by killing the child.
// Resolves with { status, rawOutput, conversationId, errorMessage }.
function executeAgy(cwd, args, logFile) {
  return new Promise((resolve) => {
    const agyArgs = buildAgyArgs(args);
    const before = args.resume ? null : snapshotConversations();

    appendLog(logFile, `Exec: agy ${agyArgs.slice(0, -1).join(" ")} <prompt>`);
    appendLog(
      logFile,
      `Model: ${args.model || "(default)"}, Sandbox: ${args.sandbox}${args.resume ? ` (resuming ${args.resume})` : ""}`
    );
    if (args.effort) {
      appendLog(logFile, `Effort: '${args.effort}' ignored — agy encodes effort in the model name (e.g. "Gemini 3.1 Pro (High)")`);
    }
    appendLog(logFile, `Deadline: ${Math.round(args.timeoutMs / 1000)}s`);

    const startedAt = Date.now();
    let stdoutBuf = "";
    let stderrTail = "";
    let settled = false;
    let timedOut = false;

    // stdio[0] = "ignore" attaches /dev/null to fd 0. agy's TUI layer
    // (bubbletea) opens /dev/tty and dies without one; `-p` avoids the TUI, but
    // an inherited stdin can still stall the child in hook/background contexts.
    // Do not change to "pipe" or "inherit" without preserving /dev/null on stdin.
    const child = spawn("agy", agyArgs, {
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
      resolve(result);
    }

    // Unlike codex, stdout is not an event stream — it is the answer. Buffer it
    // whole and mirror it into the job log for observability.
    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      stdoutBuf += text;
      fs.appendFileSync(logFile, text, "utf8");
    });

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderrTail = (stderrTail + text).slice(-2000);
      fs.appendFileSync(logFile, text, "utf8");
    });

    child.on("error", (err) => {
      const hint =
        err.code === "ENOENT"
          ? "agy not found on PATH — install Antigravity CLI: curl -fsSL https://antigravity.google/cli/install.sh | bash"
          : err.message;
      appendLog(logFile, `Spawn error: ${hint}`);
      finish({ status: "failed", errorMessage: hint, conversationId: null, rawOutput: "" });
    });

    child.on("close", (code, signal) => {
      const rawOutput = stdoutBuf.trim();
      const conversationId = args.resume
        ? args.resume
        : captureConversationId(before, logFile);

      if (timedOut) {
        finish({
          status: "stalled",
          errorMessage: `Timed out after ${Math.round(args.timeoutMs / 1000)}s`,
          conversationId,
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
          conversationId,
          rawOutput,
        });
        return;
      }
      // agy exits 0 on its own internal timeout, printing "Error: timeout
      // waiting for response" to stdout. Treat that as stalled, not success.
      if (/^Error: timeout waiting for response/m.test(rawOutput)) {
        finish({
          status: "stalled",
          errorMessage: "agy reported: timeout waiting for response",
          conversationId,
          rawOutput,
        });
        return;
      }
      if (conversationId) appendLog(logFile, `Conversation: ${conversationId}`);
      appendLog(logFile, "Completed successfully");
      finish({ status: "completed", conversationId, rawOutput });
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

  appendLog(logFile, `Starting ${args.kind} task (foreground, backend=agy)`);

  const result = await executeAgy(cwd, args, logFile);

  // threadId is the shared job-record field name across backends; for agy it
  // carries the conversation uuid so /cc-suite:continue works uniformly.
  upsertJob(cwd, {
    id: jobId,
    status: result.status,
    threadId: result.conversationId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.conversationId || null,
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });

  const output = {
    jobId,
    status: result.status,
    threadId: result.conversationId || null,
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

  appendLog(logFile, `Queued ${args.kind} task (background, backend=agy)`);

  const childArgv = [
    fileURLToPath(import.meta.url),
    "--kind", args.kind,
    "--model", args.model || "",
    "--sandbox", args.sandbox,
    "--timeout-ms", String(args.timeoutMs),
    "--session-id", sessionId || "",
    "--summary", args.summary || "",
  ];
  if (args.mode) childArgv.push("--mode", args.mode);
  for (const dir of args.addDirs) childArgv.push("--add-dir", dir);
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
  appendLog(logFile, "Background worker started (backend=agy)");

  const result = await executeAgy(cwd, args, logFile);

  upsertJob(cwd, {
    id: jobId,
    status: result.status,
    threadId: result.conversationId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.conversationId || null,
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
