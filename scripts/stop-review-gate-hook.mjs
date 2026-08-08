#!/usr/bin/env node

import process from "node:process";
import { spawnSync } from "node:child_process";

import { readHookInput } from "./lib/hook-input.mjs";
import { getConfig, listJobs } from "./lib/state.mjs";
import { sortJobsNewestFirst, SESSION_ID_ENV } from "./lib/job-control.mjs";
import { binaryAvailable } from "./lib/process.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const STOP_REVIEW_TIMEOUT_MS = 15 * 60 * 1000;
// Use the user's configured Codex default unless an explicit override is
// supplied. A plugin-wide model slug is not valid for every account.
const STOP_REVIEW_MODEL = process.env.CC_SUITE_REVIEW_MODEL?.trim() || null;

function emitDecision(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function logNote(message) {
  if (message) process.stderr.write(`${message}\n`);
}

function filterJobsForCurrentSession(jobs, input = {}) {
  const sessionId = input.session_id || process.env[SESSION_ID_ENV] || null;
  if (!sessionId) return jobs;
  return jobs.filter((j) => j.sessionId === sessionId);
}

function buildReviewPrompt(input = {}) {
  const lastMessage = String(input.last_assistant_message ?? "").trim();
  const parts = [
    "You are an adversarial code reviewer.",
    "The code and changes you are reviewing were produced by Anthropic's Claude (a competing AI system). Evaluate them with full rigor — do not defer to them or assume correctness because an AI wrote them.",
    "Review the pending changes in this worktree: use `git status` and `git diff HEAD`, plus untracked files, to enumerate exactly what is uncommitted.",
    "Session-scoped attribution is not available, so some pending changes may predate this session — review everything pending and flag issues regardless of author.",
    "Focus on: correctness, security vulnerabilities, logic errors, missing edge cases, and regressions.",
    "",
    "Output format:",
    "First line MUST be exactly one of:",
    '  ALLOW: <short reason> — if changes are safe',
    '  BLOCK: <short reason> — if changes have issues that need fixing',
    "",
    "Then provide details of any issues found.",
  ];

  if (lastMessage) {
    parts.push("", "Previous Claude response:", lastMessage);
  }

  return parts.join("\n");
}

function runStopReview(cwd, input = {}) {
  const prompt = buildReviewPrompt(input);
  const childEnv = {
    ...process.env,
    ...(input.session_id ? { [SESSION_ID_ENV]: input.session_id } : {}),
  };

  // Use codex CLI directly for the review. stdio[0] = "ignore" makes Node
  // attach /dev/null to the child's fd 0 — equivalent to `codex exec ... <
  // /dev/null` from a shell. Required because this hook runs in a no-TTY
  // background context where `codex exec` can otherwise hang on stdin.
  const codexArgs = ["exec"];
  if (STOP_REVIEW_MODEL) codexArgs.push("--model", STOP_REVIEW_MODEL);
  // Current Codex CLI releases do not support --approval-policy or
  // --ask-for-approval. The read-only sandbox is sufficient for this review.
  codexArgs.push("--sandbox", "read-only", "--color", "never", prompt);

  const result = spawnSync(
    "codex",
    codexArgs,
    {
      cwd,
      env: childEnv,
      encoding: "utf8",
      timeout: STOP_REVIEW_TIMEOUT_MS,
      stdio: ["ignore", "pipe", "pipe"],
    }
  );

  if (result.error?.code === "ETIMEDOUT") {
    return {
      ok: false,
      reason: "Stop-time review timed out after 15 minutes. Run /cc-suite:audit manually.",
    };
  }

  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || "").trim();
    return {
      ok: false,
      reason: detail
        ? `Stop-time review failed: ${detail}`
        : "Stop-time review failed. Run /cc-suite:audit manually.",
    };
  }

  return parseStopReviewOutput(result.stdout);
}

function parseStopReviewOutput(rawOutput) {
  const text = String(rawOutput ?? "").trim();
  if (!text) {
    return {
      ok: false,
      reason: "Stop-time review returned no output. Run /cc-suite:audit manually.",
    };
  }

  const firstLine = text.split(/\r?\n/, 1)[0].trim();
  if (firstLine.startsWith("ALLOW:")) {
    return { ok: true, reason: null };
  }
  if (firstLine.startsWith("BLOCK:")) {
    const reason = firstLine.slice("BLOCK:".length).trim() || text;
    return {
      ok: false,
      reason: `Stop-time review found issues: ${reason}`,
    };
  }

  return {
    ok: false,
    reason: "Stop-time review returned unexpected output. Run /cc-suite:audit manually.",
  };
}

function main() {
  const input = readHookInput();
  const cwd = input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const config = getConfig(workspaceRoot);

  // Check for running jobs
  const jobs = sortJobsNewestFirst(
    filterJobsForCurrentSession(listJobs(workspaceRoot), input)
  );
  const runningJob = jobs.find(
    (j) => j.status === "queued" || j.status === "running"
  );
  const runningNote = runningJob
    ? `Codex job ${runningJob.id} is still running. Use /cc-suite:cancel ${runningJob.id} to stop it.`
    : null;

  // If review gate is disabled, just log and exit
  if (!config.stopReviewGate) {
    logNote(runningNote);
    return;
  }

  // Check codex availability. The gate is opt-in, so fail closed: a missing
  // reviewer must block like any other review failure, not silently allow.
  const codexStatus = binaryAvailable("codex");
  if (!codexStatus.available) {
    const reason = `Stop-time review gate is enabled but the Codex CLI is unavailable (${codexStatus.detail}). Install the codex CLI, or disable the review gate, then retry.`;
    emitDecision({
      decision: "block",
      reason: runningNote ? `${runningNote} ${reason}` : reason,
    });
    return;
  }

  // Run the review
  const review = runStopReview(cwd, input);
  if (!review.ok) {
    emitDecision({
      decision: "block",
      reason: runningNote
        ? `${runningNote} ${review.reason}`
        : review.reason,
    });
    return;
  }

  logNote(runningNote);
}

main();
