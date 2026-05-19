#!/usr/bin/env node
// codex-runner.mjs — Run Codex tasks in foreground or background with job tracking.
//
// Usage:
//   node codex-runner.mjs --kind <kind> --model <model> --effort <effort> \
//     --sandbox <sandbox> [--background] [--session-id <id>] [--summary <text>] \
//     -- <prompt>
//
// In foreground mode, prints the result to stdout and exits.
// In background mode, detaches and writes result to the job file.

import fs from "node:fs";
import process from "node:process";
import { spawn, spawnSync } from "node:child_process";

import {
  generateJobId,
  upsertJob,
  writeJobFile,
  resolveJobLogFile,
} from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

function parseArgs(argv) {
  const args = {
    kind: "job",
    model: null,
    effort: "medium",
    sandbox: "read-only",
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

function runCodexSync(cwd, args) {
  const codexArgs = ["exec"];
  if (args.model) codexArgs.push("--model", args.model);
  codexArgs.push("--sandbox", args.sandbox);
  codexArgs.push("--approval-policy", "never");
  codexArgs.push("--quiet");
  codexArgs.push(args.prompt);

  return spawnSync("codex", codexArgs, {
    cwd,
    encoding: "utf8",
    timeout: 30 * 60 * 1000, // 30 minute timeout
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      CODEX_REASONING_EFFORT: args.effort,
    },
  });
}

function runForeground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;

  // Register job
  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    status: "running",
    summary: args.summary || `${args.kind} task`,
    sessionId,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    logFile,
  });

  appendLog(logFile, `Starting ${args.kind} task`);
  appendLog(logFile, `Model: ${args.model}, Effort: ${args.effort}, Sandbox: ${args.sandbox}`);

  const result = runCodexSync(cwd, args);

  if (result.error || result.status !== 0) {
    const errorMsg = result.error?.message || result.stderr?.trim() || `exit ${result.status}`;
    appendLog(logFile, `Failed: ${errorMsg}`);
    upsertJob(cwd, {
      id: jobId,
      status: "failed",
      completedAt: new Date().toISOString(),
      errorMessage: errorMsg,
    });
    writeJobFile(cwd, jobId, { error: errorMsg });

    const output = { jobId, status: "failed", error: errorMsg };
    process.stdout.write(JSON.stringify(output) + "\n");
    process.exit(1);
  }

  appendLog(logFile, "Completed successfully");
  upsertJob(cwd, {
    id: jobId,
    status: "completed",
    completedAt: new Date().toISOString(),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.stdout,
    threadId: null,
  });

  const output = {
    jobId,
    status: "completed",
    rawOutput: result.stdout,
  };
  process.stdout.write(JSON.stringify(output) + "\n");
}

function runBackground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;

  // Register job as queued
  upsertJob(cwd, {
    id: jobId,
    kind: args.kind,
    status: "queued",
    summary: args.summary || `${args.kind} task`,
    sessionId,
    logFile,
  });

  appendLog(logFile, `Queued ${args.kind} task (background)`);

  // Spawn detached child to do the actual work
  const child = spawn(
    process.execPath,
    [
      import.meta.url.replace("file://", ""),
      "--kind", args.kind,
      "--model", args.model || "",
      "--effort", args.effort,
      "--sandbox", args.sandbox,
      "--session-id", sessionId || "",
      "--summary", args.summary || "",
      "--", args.prompt,
    ],
    {
      cwd,
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        CODEX_TOOLKIT_BACKGROUND_JOB_ID: jobId,
      },
    }
  );

  // Update job with child PID
  upsertJob(cwd, {
    id: jobId,
    status: "running",
    pid: child.pid,
    startedAt: new Date().toISOString(),
  });

  child.unref();

  const output = { jobId, status: "queued", message: `Job ${jobId} started in background.` };
  process.stdout.write(JSON.stringify(output) + "\n");
}

function main() {
  const args = parseArgs(process.argv);

  if (!args.prompt) {
    process.stderr.write("Error: no prompt provided. Use -- <prompt>\n");
    process.exit(1);
  }

  const cwd = resolveWorkspaceRoot(process.cwd());

  // If this is a background worker (spawned by runBackground), run as foreground
  if (process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID) {
    // Reuse existing job ID from parent
    const existingJobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID;
    const logFile = resolveJobLogFile(cwd, existingJobId);

    appendLog(logFile, "Background worker started");
    const result = runCodexSync(cwd, args);

    if (result.error || result.status !== 0) {
      const errorMsg = result.error?.message || result.stderr?.trim() || `exit ${result.status}`;
      appendLog(logFile, `Failed: ${errorMsg}`);
      upsertJob(cwd, {
        id: existingJobId,
        status: "failed",
        completedAt: new Date().toISOString(),
        errorMessage: errorMsg,
      });
      writeJobFile(cwd, existingJobId, { error: errorMsg });
      return;
    }

    appendLog(logFile, "Completed successfully");
    upsertJob(cwd, {
      id: existingJobId,
      status: "completed",
      completedAt: new Date().toISOString(),
    });
    writeJobFile(cwd, existingJobId, {
      rawOutput: result.stdout,
      threadId: null,
    });
    return;
  }

  if (args.background) {
    runBackground(cwd, args);
  } else {
    runForeground(cwd, args);
  }
}

main();
