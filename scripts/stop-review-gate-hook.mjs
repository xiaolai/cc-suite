#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";
import { spawnSync } from "node:child_process";

import { getConfig, listJobs } from "./lib/state.mjs";
import { sortJobsNewestFirst, SESSION_ID_ENV } from "./lib/job-control.mjs";
import { binaryAvailable } from "./lib/process.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const STOP_REVIEW_TIMEOUT_MS = 15 * 60 * 1000;

function readHookInput() {
  const raw = fs.readFileSync(0, "utf8").trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

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
    "Review the changes Claude made in this session.",
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

  // Use codex CLI directly for the review
  const result = spawnSync(
    "codex",
    [
      "exec",
      "--model", "codex-mini",
      "--sandbox", "read-only",
      "--approval-policy", "never",
      "--quiet",
      prompt,
    ],
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
      reason: "Stop-time review timed out after 15 minutes. Run /codex-toolkit:audit --wait manually.",
    };
  }

  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || "").trim();
    return {
      ok: false,
      reason: detail
        ? `Stop-time review failed: ${detail}`
        : "Stop-time review failed. Run /codex-toolkit:audit manually.",
    };
  }

  return parseStopReviewOutput(result.stdout);
}

function parseStopReviewOutput(rawOutput) {
  const text = String(rawOutput ?? "").trim();
  if (!text) {
    return {
      ok: false,
      reason: "Stop-time review returned no output. Run /codex-toolkit:audit manually.",
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
    reason: "Stop-time review returned unexpected output. Run /codex-toolkit:audit manually.",
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
    ? `Codex job ${runningJob.id} is still running. Use /codex-toolkit:cancel ${runningJob.id} to stop it.`
    : null;

  // If review gate is disabled, just log and exit
  if (!config.stopReviewGate) {
    logNote(runningNote);
    return;
  }

  // Check codex availability
  const codexStatus = binaryAvailable("codex");
  if (!codexStatus.available) {
    logNote("Codex CLI not available for stop-time review.");
    logNote(runningNote);
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
