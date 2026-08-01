#!/usr/bin/env node
// qwen-runner.mjs — Run bounded, read-only Qwen reviews with strict stream-json
// completion detection, exact-file policy checks, hash verification, bounded
// resume, and the shared cc-suite job surface.
//
// Usage:
//   node qwen-runner.mjs [--model <model>] [--target <file>]...
//     [--max-resumes <0..5>]
//     [--attempt-timeout-ms <ms>] [--idle-timeout-ms <ms>]
//     [--timeout-ms <ms>] [--debug-capture] [--background]
//     [--session-id <id>] [--summary <text>] -- <review prompt>

import fs from "node:fs";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import {
  generateJobId,
  resolveJobLogFile,
  upsertJob,
  writeJobFile,
} from "./lib/state.mjs";
import { withDelegationBoundary } from "./lib/delegation-boundary.mjs";
import {
  JsonlDecoder,
  QwenStreamError,
  consumeQwenEvent,
  createQwenStreamState,
  describeQwenEvent,
  parseQwenJsonLine,
  removeStagedReview,
  snapshotReviewTargets,
  stageReviewTargets,
  verifyReviewTargets,
} from "./lib/qwen-stream.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const DEFAULT_JOB_TIMEOUT_MS = 15 * 60 * 1000;
const DEFAULT_ATTEMPT_TIMEOUT_MS = 5 * 60 * 1000;
const DEFAULT_IDLE_TIMEOUT_MS = 4 * 60 * 1000;
const DEFAULT_MAX_RESUMES = 2;
const HEARTBEAT_MS = 30 * 1000;
const EXIT_GRACE_MS = 10 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;
const MAX_RESUMES_LIMIT = 5;

// Qwen 0.21.0 through 0.21.2 ignore --core-tools in Safe Mode. Deny every known
// non-review tool explicitly, then verify the actual init tool list before
// accepting any later stream event. A future unlisted tool therefore fails the
// init check.
const QWEN_FORBIDDEN_TOOLS = [
  "edit",
  "write_file",
  "grep_search",
  "glob",
  "run_shell_command",
  "todo_write",
  "get_goal",
  "update_goal",
  "save_memory",
  "agent",
  "skill",
  "exit_plan_mode",
  "enter_plan_mode",
  "web_fetch",
  "web_search",
  "image_gen",
  "list_directory",
  "lsp",
  "ask_user_question",
  "cron_create",
  "cron_list",
  "cron_delete",
  "loop_wakeup",
  "create_sub_session",
  "list_agents",
  "task_stop",
  "task_create",
  "task_update",
  "task_list",
  "team_create",
  "team_delete",
  "team_plan_approval",
  "send_message",
  "structured_output",
  "monitor",
  "notebook_edit",
  "tool_search",
  "read_mcp_resource",
  "zoom_image",
  "enter_worktree",
  "exit_worktree",
  "workflow",
  "artifact",
  "record_artifact",
  "computer_use__bring_to_front",
  "computer_use__check_for_update",
  "computer_use__check_permissions",
  "computer_use__click",
  "computer_use__double_click",
  "computer_use__drag",
  "computer_use__end_session",
  "computer_use__get_accessibility_tree",
  "computer_use__get_agent_cursor_state",
  "computer_use__get_config",
  "computer_use__get_cursor_position",
  "computer_use__get_recording_state",
  "computer_use__get_screen_size",
  "computer_use__get_window_state",
  "computer_use__hotkey",
  "computer_use__kill_app",
  "computer_use__launch_app",
  "computer_use__list_apps",
  "computer_use__list_windows",
  "computer_use__move_cursor",
  "computer_use__page",
  "computer_use__press_key",
  "computer_use__replay_trajectory",
  "computer_use__right_click",
  "computer_use__scroll",
  "computer_use__set_agent_cursor_enabled",
  "computer_use__set_agent_cursor_motion",
  "computer_use__set_agent_cursor_style",
  "computer_use__set_config",
  "computer_use__set_value",
  "computer_use__start_recording",
  "computer_use__start_session",
  "computer_use__stop_recording",
  "computer_use__type_text",
  "computer_use__zoom",
];

const ACTIVE_QWEN_CHILDREN = new Set();
const ACTIVE_REVIEW_STAGES = new Set();
const ACTIVE_JOB_CONTEXTS = new Set();
let handlingSignal = false;
let receivedSignal = null;

const AUTO_RESUME_PROMPT = [
  "The previous headless turn ended without a valid terminal result event.",
  "Continue the same bounded review from the restored session.",
  "Do not repeat file reads unless the review cannot be completed from restored context.",
  "Return the final review directly.",
].join(" ");

function parseIntegerFlag(flag, value, minimum, maximum = Number.MAX_SAFE_INTEGER) {
  if (!/^\d+$/.test(value)) {
    throw new QwenStreamError("invalid_arguments", `${flag} must be a decimal integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    const range = maximum === Number.MAX_SAFE_INTEGER
      ? `an integer >= ${minimum}`
      : `an integer from ${minimum} to ${maximum}`;
    throw new QwenStreamError("invalid_arguments", `${flag} must be ${range}`);
  }
  return parsed;
}

function optionValue(argv, index, flag) {
  const value = argv[index + 1];
  if (value === undefined || value === "--" || value.startsWith("--")) {
    throw new QwenStreamError("invalid_arguments", `${flag} requires a value`);
  }
  return value;
}

function parseArgs(argv) {
  const args = {
    kind: "qwen-review",
    model: null,
    targets: [],
    maxResumes: DEFAULT_MAX_RESUMES,
    attemptTimeoutMs: DEFAULT_ATTEMPT_TIMEOUT_MS,
    idleTimeoutMs: DEFAULT_IDLE_TIMEOUT_MS,
    timeoutMs: DEFAULT_JOB_TIMEOUT_MS,
    debugCapture: false,
    background: false,
    sessionId: null,
    summary: null,
    prompt: null,
  };

  let i = 2;
  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case "--kind":
        args.kind = optionValue(argv, i, arg);
        i += 2;
        continue;
      case "--model":
        args.model = optionValue(argv, i, arg);
        i += 2;
        continue;
      case "--target":
        args.targets.push(optionValue(argv, i, arg));
        i += 2;
        continue;
      case "--max-resumes":
        args.maxResumes = parseIntegerFlag(
          arg,
          optionValue(argv, i, arg),
          0,
          MAX_RESUMES_LIMIT
        );
        i += 2;
        continue;
      case "--attempt-timeout-ms":
        args.attemptTimeoutMs = parseIntegerFlag(arg, optionValue(argv, i, arg), 1);
        i += 2;
        continue;
      case "--idle-timeout-ms":
        args.idleTimeoutMs = parseIntegerFlag(arg, optionValue(argv, i, arg), 1);
        i += 2;
        continue;
      case "--timeout-ms":
        args.timeoutMs = parseIntegerFlag(arg, optionValue(argv, i, arg), 1);
        i += 2;
        continue;
      case "--debug-capture":
        args.debugCapture = true;
        i += 1;
        continue;
      case "--background":
        args.background = true;
        i += 1;
        continue;
      case "--session-id":
        args.sessionId = optionValue(argv, i, arg);
        i += 2;
        continue;
      case "--summary":
        args.summary = optionValue(argv, i, arg);
        i += 2;
        continue;
      case "--":
        args.prompt = argv.slice(i + 1).join(" ");
        i = argv.length;
        continue;
      default:
        throw new QwenStreamError("invalid_arguments", `Unknown argument: ${arg}`);
    }
  }
  return args;
}

function excludedTools(targets) {
  return targets.length === 0
    ? [...QWEN_FORBIDDEN_TOOLS, "read_file"]
    : QWEN_FORBIDDEN_TOOLS;
}

function appendLog(logFile, message) {
  fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${message}\n`, "utf8");
}

function redactDiagnostic(text) {
  return String(text)
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1[REDACTED]")
    .replace(/\b(sk-(?:proj-)?|sk-ant-|gh[pousr]_)[A-Za-z0-9_-]{12,}\b/g, "$1[REDACTED]")
    .replace(/\b(AKIA|ASIA)[A-Z0-9]{12,}\b/g, "$1[REDACTED]")
    .replace(/((?:TOKEN|API_KEY|SECRET|PASSWORD)\s*[=:]\s*)[^\s,;]+/gi, "$1[REDACTED]");
}

function reviewPolicyPrompt(targets) {
  if (targets.length === 0) {
    return [
      "This is a bounded, tool-free independent review.",
      "Do not call any tool, MCP server, subagent, computer-use surface, shell, write, or edit operation.",
    ].join(" ");
  }
  return [
    "This is a bounded, read-only independent review.",
    "The only permitted tool is read_file, and only for these isolated copies (original label => staged path):",
    targets.map((target) => `${JSON.stringify(target.displayPath)} => ${JSON.stringify(target.realPath)}`).join(", "),
    "Do not call MCP servers, subagents, computer-use surfaces, shell, write, edit, glob, grep, or directory-listing tools.",
  ].join(" ");
}

function boundedPrompt(prompt, targets) {
  return withDelegationBoundary(
    `${reviewPolicyPrompt(targets)} The calling agent retains final judgment; your output is critique, not evidence.\n\n${prompt}`
  );
}

function buildQwenArgs(args, targets, resumeId, prompt, attemptTimeoutMs) {
  const maxToolCalls = targets.length === 0 ? 0 : Math.max(4, targets.length * 4);
  const qwenArgs = [
    "--safe-mode",
    "--sandbox",
    "--approval-mode", "plan",
    "--output-format", "stream-json",
    "--max-wall-time", `${Math.max(1, Math.ceil(attemptTimeoutMs / 1000))}s`,
    "--max-session-turns", "30",
    "--max-tool-calls", String(maxToolCalls),
    "--exclude-tools", excludedTools(targets).join(","),
  ];
  if (args.model) qwenArgs.push("--model", args.model);
  if (resumeId) qwenArgs.push("--resume", resumeId);
  qwenArgs.push("--prompt", boundedPrompt(prompt, targets));
  return qwenArgs;
}

function debugCapturePaths(logFile, attempt) {
  const stem = logFile.endsWith(".log") ? logFile.slice(0, -4) : logFile;
  return {
    stdout: `${stem}.attempt-${attempt}.stdout.jsonl`,
    stderr: `${stem}.attempt-${attempt}.stderr.log`,
  };
}

function appendPrivate(filePath, chunk) {
  const fd = fs.openSync(filePath, "a", 0o600);
  try {
    fs.fchmodSync(fd, 0o600);
    fs.writeSync(fd, chunk);
  } finally {
    fs.closeSync(fd);
  }
}

function sandboxEnvironment() {
  const env = { ...process.env };
  const configured = env.QWEN_SANDBOX;
  const supported = new Set(["docker", "podman", "sandbox-exec"]);
  env.QWEN_SANDBOX = supported.has(configured) ? configured : "true";
  if (process.platform === "darwin" && env.QWEN_SANDBOX === "true") {
    env.QWEN_SANDBOX = "sandbox-exec";
  }
  if (env.QWEN_SANDBOX === "sandbox-exec") {
    env.SEATBELT_PROFILE = "restrictive-open";
  }
  return env;
}

function cleanupReviewStage(stage) {
  ACTIVE_REVIEW_STAGES.delete(stage);
  removeStagedReview(stage);
}

function markActiveJobsInterrupted(signal) {
  const errorMessage = `Qwen review runner interrupted by ${signal}`;
  const completedAt = new Date().toISOString();
  for (const context of ACTIVE_JOB_CONTEXTS) {
    try {
      upsertJob(context.cwd, {
        id: context.jobId,
        status: "failed",
        phase: "failed",
        errorCode: "interrupted",
        errorMessage,
        completedAt,
      });
      writeJobFile(context.cwd, context.jobId, {
        rawOutput: "",
        threadId: null,
        attempts: [],
        error: errorMessage,
        errorCode: "interrupted",
      });
    } catch {
      // Continue terminating the child and cleaning every private stage.
    }
  }
}

// Terminate a Qwen child and any subprocesses it spawned (sandbox providers,
// containers, helpers) by signalling its whole process group; fall back to the
// direct pid when group signalling is unavailable. The child is spawned
// detached so it leads its own process group.
function killQwenTree(child, signal) {
  if (!child.pid) return;
  if (process.platform !== "win32") {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch {
      // No such group or not a group leader — fall through to the direct pid.
    }
  }
  try {
    child.kill(signal);
  } catch {
    // Already gone.
  }
}

for (const [signal, exitCode] of [["SIGHUP", 129], ["SIGINT", 130], ["SIGTERM", 143]]) {
  process.once(signal, () => {
    if (handlingSignal) return;
    handlingSignal = true;
    receivedSignal = signal;
    process.exitCode = exitCode;
    for (const child of ACTIVE_QWEN_CHILDREN) {
      killQwenTree(child, "SIGTERM");
    }
    for (const stage of ACTIVE_REVIEW_STAGES) {
      try {
        removeStagedReview(stage);
      } catch {
        // The process is terminating; do not leave another stage unexamined.
      }
    }
    markActiveJobsInterrupted(signal);
    setTimeout(() => {
      for (const child of ACTIVE_QWEN_CHILDREN) {
        killQwenTree(child, "SIGKILL");
      }
      setTimeout(() => process.exit(exitCode), 100);
    }, 1000);
  });
}

function executeQwenAttempt(cwd, args, targets, logFile, attempt, resumeId, prompt, attemptTimeoutMs) {
  return new Promise((resolve) => {
    const qwenArgs = buildQwenArgs(args, targets, resumeId, prompt, attemptTimeoutMs);
    const state = createQwenStreamState({ cwd, targets });
    const decoder = new JsonlDecoder();
    const capture = args.debugCapture ? debugCapturePaths(logFile, attempt) : null;
    let stderrTail = "";
    let settled = false;
    let timedOut = false;
    let timeoutReason = null;
    let protocolError = null;
    let childClosed = false;
    let idleTimer = null;
    let exitGrace = null;
    let killTimer = null;

    appendLog(
      logFile,
      `Attempt ${attempt}: qwen --safe-mode --sandbox --approval-mode plan --output-format stream-json${resumeId ? ` --resume ${resumeId}` : ""} <prompt>`
    );
    appendLog(
      logFile,
      `Attempt ${attempt}: deadline=${Math.round(attemptTimeoutMs / 1000)}s idle=${Math.round(args.idleTimeoutMs / 1000)}s targets=${targets.length}`
    );
    if (capture) {
      appendLog(logFile, `Attempt ${attempt}: raw debug capture enabled (may contain reviewed content)`);
    }

    // detached: the child leads its own process group so killQwenTree can
    // terminate the whole tree (sandbox providers included), not just qwen.
    const child = spawn("qwen", qwenArgs, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      detached: process.platform !== "win32",
      env: sandboxEnvironment(),
    });
    ACTIVE_QWEN_CHILDREN.add(child);

    const startedAt = Date.now();
    const heartbeat = setInterval(() => {
      appendLog(
        logFile,
        `Attempt ${attempt}: still running (${Math.round((Date.now() - startedAt) / 1000)}s, events=${state.events}, tools=${state.toolCalls.length})`
      );
    }, HEARTBEAT_MS);

    function clearTimers() {
      clearInterval(heartbeat);
      clearTimeout(deadline);
      clearTimeout(idleTimer);
      clearTimeout(exitGrace);
      clearTimeout(killTimer);
    }

    function finish(result) {
      if (settled) return;
      settled = true;
      clearTimers();
      resolve({
        ...result,
        sessionId: state.sessionId || resumeId || null,
        permissionMode: state.permissionMode,
        advertisedTools: state.advertisedTools,
        toolBoundaryVerified: state.toolBoundaryVerified,
        toolCalls: state.toolCalls,
        usage: state.usage,
        debugCapture: capture,
      });
    }

    function terminate(reason) {
      if (childClosed) return;
      appendLog(logFile, `Attempt ${attempt}: terminating (${reason})`);
      killQwenTree(child, "SIGTERM");
      killTimer = setTimeout(() => {
        if (!childClosed) killQwenTree(child, "SIGKILL");
      }, SIGKILL_GRACE_MS);
    }

    function triggerTimeout(reason) {
      if (settled || timedOut) return;
      timedOut = true;
      timeoutReason = reason;
      terminate(reason);
    }

    function resetIdleTimer() {
      clearTimeout(idleTimer);
      idleTimer = setTimeout(
        () => triggerTimeout(`no stdout/stderr event for ${Math.round(args.idleTimeoutMs / 1000)}s`),
        args.idleTimeoutMs
      );
    }

    const deadline = setTimeout(
      () => triggerTimeout(`attempt deadline ${Math.round(attemptTimeoutMs / 1000)}s exceeded`),
      attemptTimeoutMs
    );
    resetIdleTimer();

    function consumeLine(line) {
      const event = parseQwenJsonLine(line);
      consumeQwenEvent(state, event);
      appendLog(logFile, `Attempt ${attempt}: ${describeQwenEvent(event)}`);
      if (event.type === "result" && !exitGrace) {
        exitGrace = setTimeout(
          () => terminate(`process did not exit within ${Math.round(EXIT_GRACE_MS / 1000)}s after result`),
          EXIT_GRACE_MS
        );
      }
    }

    child.stdout.on("data", (chunk) => {
      resetIdleTimer();
      if (capture) appendPrivate(capture.stdout, chunk);
      if (protocolError) return;
      try {
        for (const line of decoder.push(chunk)) consumeLine(line);
      } catch (error) {
        if (!protocolError) {
          protocolError = error instanceof QwenStreamError
            ? error
            : new QwenStreamError("stream_failure", error.message);
        }
        appendLog(logFile, `Attempt ${attempt}: ${protocolError.code}: ${redactDiagnostic(protocolError.message)}`);
        terminate(protocolError.code);
      }
    });

    child.stderr.on("data", (chunk) => {
      resetIdleTimer();
      if (capture) appendPrivate(capture.stderr, chunk);
      stderrTail = (stderrTail + chunk.toString("utf8")).slice(-4000);
    });

    child.on("error", (error) => {
      const message = error.code === "ENOENT"
        ? "qwen not found on PATH — install Qwen Code, then run /cc-suite:qwen-preflight"
        : error.message;
      appendLog(logFile, `Attempt ${attempt}: spawn error: ${redactDiagnostic(message)}`);
      finish({
        outcome: "failed",
        errorCode: error.code === "ENOENT" ? "qwen_not_found" : "spawn_failure",
        errorMessage: message,
        rawOutput: "",
      });
    });

    child.on("close", (code, signal) => {
      childClosed = true;
      ACTIVE_QWEN_CHILDREN.delete(child);
      clearTimeout(killTimer);
      if (settled) return;
      if (receivedSignal) {
        finish({
          outcome: "failed",
          errorCode: "interrupted",
          errorMessage: `Qwen review runner interrupted by ${receivedSignal}`,
          rawOutput: "",
        });
        return;
      }
      if (!protocolError) {
        try {
          for (const line of decoder.finish()) consumeLine(line);
        } catch (error) {
          protocolError = error instanceof QwenStreamError
            ? error
            : new QwenStreamError("stream_failure", error.message);
        }
      }

      if (timedOut) {
        finish({
          outcome: "incomplete",
          errorCode: "attempt_timeout",
          errorMessage: timeoutReason,
          rawOutput: "",
        });
        return;
      }
      if (protocolError) {
        finish({
          outcome: "failed",
          errorCode: protocolError.code,
          errorMessage: protocolError.message,
          rawOutput: "",
        });
        return;
      }
      if (state.terminalError) {
        finish({
          outcome: "failed",
          errorCode: "qwen_terminal_error",
          errorMessage: state.terminalError,
          rawOutput: "",
        });
        return;
      }
      if (state.resultSeen && state.emptyResult) {
        finish({
          outcome: "incomplete",
          errorCode: "empty_result",
          errorMessage: "Qwen emitted a success result with an empty result string",
          rawOutput: "",
        });
        return;
      }
      if (state.result) {
        if (code !== 0) {
          finish({
            outcome: "failed",
            errorCode: "exit_mismatch",
            errorMessage: `Qwen emitted success but exited ${code === null ? `by signal ${signal}` : `with code ${code}`}`,
            rawOutput: state.result,
          });
          return;
        }
        finish({ outcome: "completed", rawOutput: state.result });
        return;
      }

      const exit = code === null ? `signal ${signal}` : `exit ${code}`;
      const stderr = redactDiagnostic(stderrTail.trim());
      finish({
        outcome: "incomplete",
        errorCode: "missing_result",
        errorMessage: `Qwen ended without a terminal result (${exit})${stderr ? `: ${stderr}` : ""}`,
        rawOutput: "",
      });
    });
  });
}

async function executeQwen(cwd, args, targets, integrityTargets, logFile) {
  const jobStarted = Date.now();
  let resumeId = null;
  let prompt = args.prompt;
  const attempts = [];

  for (let index = 0; index <= args.maxResumes; index += 1) {
    const remaining = args.timeoutMs - (Date.now() - jobStarted);
    if (remaining <= 0) {
      return {
        status: "stalled",
        errorCode: "job_timeout",
        errorMessage: `Qwen job exceeded ${Math.round(args.timeoutMs / 1000)}s`,
        sessionId: resumeId || null,
        rawOutput: "",
        attempts,
      };
    }

    const attempt = index + 1;
    const result = await executeQwenAttempt(
      cwd,
      args,
      targets,
      logFile,
      attempt,
      resumeId,
      prompt,
      Math.min(args.attemptTimeoutMs, remaining)
    );
    attempts.push({
      attempt,
      outcome: result.outcome,
      errorCode: result.errorCode ?? null,
      sessionId: result.sessionId,
      permissionMode: result.permissionMode,
      advertisedTools: result.advertisedTools,
      toolBoundaryVerified: result.toolBoundaryVerified,
      toolCalls: result.toolCalls.map((call) => ({
        name: call.name,
        path: call.displayPath,
      })),
      ...(result.debugCapture ? { debugCapture: result.debugCapture } : {}),
    });

    if (result.errorCode === "interrupted") {
      return {
        status: "failed",
        errorCode: result.errorCode,
        errorMessage: result.errorMessage,
        sessionId: result.sessionId,
        rawOutput: "",
        attempts,
      };
    }

    const hashes = verifyReviewTargets(integrityTargets);
    if (!hashes.ok) {
      appendLog(logFile, `Attempt ${attempt}: target hash mismatch`);
      return {
        status: "failed",
        errorCode: "hash_mismatch",
        errorMessage: `Review target changed: ${hashes.changed.join(", ")}`,
        sessionId: result.sessionId,
        rawOutput: "",
        attempts,
      };
    }

    if (result.outcome === "completed") {
      appendLog(logFile, `Attempt ${attempt}: completed with verified terminal result and unchanged targets`);
      return {
        status: "completed",
        sessionId: result.sessionId,
        rawOutput: result.rawOutput,
        usage: result.usage ?? null,
        attempts,
      };
    }
    if (result.outcome === "failed") {
      return {
        status: "failed",
        errorCode: result.errorCode,
        errorMessage: result.errorMessage,
        sessionId: result.sessionId,
        rawOutput: result.rawOutput || "",
        attempts,
      };
    }

    resumeId = result.sessionId;
    if (!resumeId || index >= args.maxResumes) {
      return {
        status: "stalled",
        errorCode: result.errorCode || "resume_exhausted",
        errorMessage: !resumeId
          ? `${result.errorMessage}; no Qwen session id was available to resume`
          : `${result.errorMessage}; resume limit ${args.maxResumes} exhausted`,
        sessionId: resumeId || null,
        rawOutput: "",
        attempts,
      };
    }
    appendLog(logFile, `Attempt ${attempt}: incomplete — resuming session ${resumeId}`);
    prompt = AUTO_RESUME_PROMPT;
  }

  throw new Error("unreachable");
}

function jobPayload(result) {
  return {
    rawOutput: result.rawOutput || "",
    threadId: result.sessionId || null,
    attempts: result.attempts,
    ...(result.usage ? { usage: result.usage } : {}),
    ...(result.errorMessage ? { error: result.errorMessage, errorCode: result.errorCode } : {}),
  };
}

async function runForeground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const jobContext = { cwd, jobId };
  const logFile = resolveJobLogFile(cwd, jobId);
  const hostSessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;
  const sourceTargets = snapshotReviewTargets(cwd, args.targets);

  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    kindLabel: "qwen-review",
    status: "running",
    phase: "qwen-review",
    summary: args.summary || "qwen review",
    sessionId: hostSessionId,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
    logFile,
  });
  ACTIVE_JOB_CONTEXTS.add(jobContext);

  // Any throw below (staging, execution, cleanup, persistence) must finalize
  // this job under its real id instead of leaving it recorded as running and
  // reporting jobId:null from main()'s catch-all.
  try {
    let result;
    let stage = null;
    try {
      stage = stageReviewTargets(sourceTargets);
      ACTIVE_REVIEW_STAGES.add(stage);
      appendLog(logFile, `Starting bounded Qwen review (foreground, targets=${stage.targets.length}, isolated=true)`);
      result = await executeQwen(
        stage.root,
        args,
        stage.targets,
        [...sourceTargets, ...stage.targets],
        logFile
      );
    } finally {
      if (stage) cleanupReviewStage(stage);
    }
    upsertJob(cwd, {
      id: jobId,
      status: result.status,
      phase: result.status,
      threadId: result.sessionId || null,
      attempts: result.attempts.length,
      completedAt: new Date().toISOString(),
      ...(result.errorMessage ? { errorMessage: result.errorMessage, errorCode: result.errorCode } : {}),
    });
    writeJobFile(cwd, jobId, jobPayload(result));

    process.stdout.write(JSON.stringify({
      jobId,
      status: result.status,
      threadId: result.sessionId || null,
      rawOutput: result.rawOutput || "",
      attempts: result.attempts,
      targetsVerified: result.status === "completed",
      ...(result.errorMessage ? { error: result.errorMessage, errorCode: result.errorCode } : {}),
    }) + "\n");
    if (result.status !== "completed") process.exitCode = 1;
  } catch (error) {
    const code = error instanceof QwenStreamError ? error.code : "runner_failure";
    const message = redactDiagnostic(error.message);
    // Finalize job state first: a logging failure must never leave the job
    // recorded as running.
    try {
      upsertJob(cwd, {
        id: jobId,
        status: "failed",
        phase: "failed",
        errorCode: code,
        errorMessage: message,
        completedAt: new Date().toISOString(),
      });
      writeJobFile(cwd, jobId, {
        rawOutput: "",
        threadId: null,
        attempts: [],
        error: message,
        errorCode: code,
      });
    } catch {
      // State unwritable — the stdout result below still reports the failure.
    }
    try {
      appendLog(logFile, `Foreground job failed: ${code}: ${message}`);
    } catch {
      // Log unwritable — the job state above is already finalized.
    }
    process.stdout.write(JSON.stringify({
      jobId,
      status: "failed",
      threadId: null,
      rawOutput: "",
      attempts: [],
      targetsVerified: false,
      errorCode: code,
      error: message,
    }) + "\n");
    process.exitCode = 1;
  } finally {
    ACTIVE_JOB_CONTEXTS.delete(jobContext);
  }
}

function childArgs(args) {
  const argv = [
    fileURLToPath(import.meta.url),
    "--kind", args.kind,
    "--max-resumes", String(args.maxResumes),
    "--attempt-timeout-ms", String(args.attemptTimeoutMs),
    "--idle-timeout-ms", String(args.idleTimeoutMs),
    "--timeout-ms", String(args.timeoutMs),
  ];
  if (args.sessionId) argv.push("--session-id", args.sessionId);
  if (args.summary) argv.push("--summary", args.summary);
  if (args.model) argv.push("--model", args.model);
  if (args.debugCapture) argv.push("--debug-capture");
  for (const target of args.targets) argv.push("--target", target);
  argv.push("--", args.prompt);
  return argv;
}

function runBackground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
  const hostSessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;
  snapshotReviewTargets(cwd, args.targets);

  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    kindLabel: "qwen-review",
    status: "queued",
    phase: "queued",
    summary: args.summary || "qwen review",
    sessionId: hostSessionId,
    logFile,
  });
  appendLog(logFile, `Queued bounded Qwen review (background, targets=${args.targets.length})`);

  const child = spawn(process.execPath, childArgs(args), {
    cwd,
    detached: true,
    stdio: "ignore",
    env: { ...process.env, CODEX_TOOLKIT_BACKGROUND_JOB_ID: jobId },
  });
  return new Promise((resolve) => {
    child.once("error", (error) => {
      const message = redactDiagnostic(error.message);
      upsertJob(cwd, {
        id: jobId,
        status: "failed",
        phase: "failed",
        errorCode: "spawn_failure",
        errorMessage: message,
        completedAt: new Date().toISOString(),
      });
      writeJobFile(cwd, jobId, {
        rawOutput: "",
        threadId: null,
        attempts: [],
        error: message,
        errorCode: "spawn_failure",
      });
      process.stdout.write(JSON.stringify({
        jobId,
        status: "failed",
        errorCode: "spawn_failure",
        error: message,
      }) + "\n");
      process.exitCode = 1;
      resolve();
    });
    child.once("spawn", () => {
      child.unref();
      process.stdout.write(JSON.stringify({
        jobId,
        status: "queued",
        message: `Job ${jobId} started in background.`,
      }) + "\n");
      resolve();
    });
  });
}

async function runBackgroundWorker(cwd, args, jobId) {
  const jobContext = { cwd, jobId };
  const logFile = resolveJobLogFile(cwd, jobId);
  const sourceTargets = snapshotReviewTargets(cwd, args.targets);
  upsertJob(cwd, {
    id: jobId,
    status: "running",
    phase: "qwen-review",
    pid: process.pid,
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
  });
  ACTIVE_JOB_CONTEXTS.add(jobContext);
  let result;
  let stage = null;
  try {
    stage = stageReviewTargets(sourceTargets);
    ACTIVE_REVIEW_STAGES.add(stage);
    appendLog(logFile, `Background worker started (backend=qwen, targets=${stage.targets.length}, isolated=true)`);
    result = await executeQwen(
      stage.root,
      args,
      stage.targets,
      [...sourceTargets, ...stage.targets],
      logFile
    );
  } finally {
    if (stage) cleanupReviewStage(stage);
  }
  upsertJob(cwd, {
    id: jobId,
    status: result.status,
    phase: result.status,
    threadId: result.sessionId || null,
    attempts: result.attempts.length,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage, errorCode: result.errorCode } : {}),
  });
  writeJobFile(cwd, jobId, jobPayload(result));
  ACTIVE_JOB_CONTEXTS.delete(jobContext);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv);
    if (!args.prompt?.trim()) {
      throw new QwenStreamError(
        "invalid_arguments",
        "No review prompt provided. Use -- <prompt>"
      );
    }
    if (args.kind !== "qwen-review") {
      throw new QwenStreamError(
        "invalid_arguments",
        `Unsupported job kind: ${args.kind}`
      );
    }
  } catch (error) {
    const code = error instanceof QwenStreamError ? error.code : "invalid_arguments";
    process.stdout.write(JSON.stringify({
      jobId: null,
      status: "failed",
      threadId: null,
      rawOutput: "",
      attempts: [],
      targetsVerified: false,
      errorCode: code,
      error: redactDiagnostic(error.message),
    }) + "\n");
    process.exitCode = 1;
    return;
  }

  const cwd = resolveWorkspaceRoot(process.cwd());
  try {
    const backgroundJobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID;
    if (backgroundJobId) {
      await runBackgroundWorker(cwd, args, backgroundJobId);
    } else if (args.background) {
      await runBackground(cwd, args);
    } else {
      await runForeground(cwd, args);
    }
  } catch (error) {
    const code = error instanceof QwenStreamError ? error.code : "runner_failure";
    const backgroundJobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID;
    if (backgroundJobId) {
      const message = redactDiagnostic(error.message);
      // Finalize job state first: a logging failure must never leave the job
      // recorded as running.
      upsertJob(cwd, {
        id: backgroundJobId,
        status: "failed",
        phase: "failed",
        errorCode: code,
        errorMessage: message,
        completedAt: new Date().toISOString(),
      });
      writeJobFile(cwd, backgroundJobId, {
        rawOutput: "",
        threadId: null,
        attempts: [],
        error: message,
        errorCode: code,
      });
      try {
        appendLog(resolveJobLogFile(cwd, backgroundJobId), `Background worker failed: ${code}: ${message}`);
      } catch {
        // Log unwritable — the job state above is already finalized.
      }
      process.exitCode = 1;
      return;
    }
    process.stdout.write(JSON.stringify({
      jobId: null,
      status: "failed",
      threadId: null,
      rawOutput: "",
      attempts: [],
      targetsVerified: false,
      errorCode: code,
      error: redactDiagnostic(error.message),
    }) + "\n");
    process.exitCode = 1;
  }
}

main();
