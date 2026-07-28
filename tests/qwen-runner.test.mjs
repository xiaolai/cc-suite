import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

import { cleanupDir, makeTempDir } from "./helpers.mjs";

const PLUGIN_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const RUNNER = path.join(PLUGIN_ROOT, "scripts", "qwen-runner.mjs");
const PREFLIGHT = path.join(PLUGIN_ROOT, "scripts", "qwen-preflight.sh");

const FAKE_QWEN = `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
if (process.env.FAKE_QWEN_ARGS_FILE) {
  fs.writeFileSync(process.env.FAKE_QWEN_ARGS_FILE, JSON.stringify(args));
}
if (args.includes("--version")) {
  process.stdout.write((process.env.FAKE_QWEN_VERSION || "0.21.0") + "\\n");
  process.exit(0);
}
const mode = process.env.FAKE_QWEN_MODE || "normal";
function findTarget(root) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const candidate = require("node:path").join(root, entry.name);
    if (entry.isDirectory()) {
      const nested = findTarget(candidate);
      if (nested) return nested;
    } else if (entry.isFile()) {
      return candidate;
    }
  }
  return null;
}
const target = findTarget(process.cwd());
const resumed = args.includes("--resume");
const session = "fake-qwen-session";
const emit = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
emit({ type: "system", subtype: "init", session_id: session, permission_mode: "plan" });
if (mode === "timeout-resume" && !resumed) {
  process.stdout.write('{"type":"assistant"');
  setInterval(() => {}, 1000);
} else {
  if (mode === "malformed") {
    process.stdout.write("{bad json\\n");
    process.exit(0);
  }
  if (mode === "resume" && !resumed) {
    emit({ type: "assistant", session_id: session, message: { content: [{ type: "text", text: "partial" }] } });
    process.exit(0);
  }
  if (mode === "forbidden") {
    emit({ type: "assistant", session_id: session, message: { content: [{ type: "tool_use", id: "t1", name: "agent", input: { prompt: "delegate" } }] } });
    process.exit(0);
  }
  if (mode === "wrong-target") {
    emit({ type: "assistant", session_id: session, message: { content: [{ type: "tool_use", id: "t1", name: "read_file", input: { file_path: target + ".other" } }] } });
    process.exit(0);
  }
  if (mode === "read" || mode === "mutate") {
    emit({ type: "assistant", session_id: session, message: { content: [{ type: "tool_use", id: "t1", name: "read_file", input: { file_path: target } }] } });
    emit({ type: "tool_result", session_id: session, tool_use_id: "t1" });
  }
  if (mode === "mutate") {
    fs.chmodSync(target, 0o600);
    fs.appendFileSync(target, "changed\\n");
  }
  emit({ type: "assistant", session_id: session, message: { content: [{ type: "text", text: resumed ? "resumed review" : "review" }] } });
  if (mode === "terminal-error") {
    emit({ type: "result", subtype: "error", session_id: session, is_error: true, result: "provider failed" });
    process.exit(0);
  }
  if (mode === "empty") {
    emit({ type: "result", subtype: "success", session_id: session, is_error: false, result: "" });
    process.exit(0);
  }
  emit({ type: "result", subtype: "success", session_id: session, is_error: false, result: resumed ? "resumed review" : "review" });
  if (mode === "exit-mismatch") process.exitCode = 1;
}
`;

function setup() {
  const dir = makeTempDir("qwen-runner-");
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  const qwen = path.join(bin, "qwen");
  fs.writeFileSync(qwen, FAKE_QWEN, { mode: 0o755 });
  const target = path.join(dir, "draft.md");
  const argsFile = path.join(dir, "qwen-args.json");
  fs.writeFileSync(target, "unchanged\n");
  return { dir, bin, target, argsFile };
}

function runFake(mode, extraArgs = [], options = {}) {
  const fixture = setup();
  const args = [
    RUNNER,
    "--max-resumes", String(options.maxResumes ?? 0),
    "--attempt-timeout-ms", String(options.attemptTimeoutMs ?? 5000),
    "--idle-timeout-ms", String(options.idleTimeoutMs ?? 5000),
    "--timeout-ms", String(options.timeoutMs ?? 10000),
    ...extraArgs,
    "--",
    "Review the supplied material.",
  ];
  const result = spawnSync(process.execPath, args, {
    cwd: fixture.dir,
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
    env: {
      ...process.env,
      PATH: `${fixture.bin}${path.delimiter}${process.env.PATH}`,
      CLAUDE_PLUGIN_DATA: path.join(fixture.dir, "plugin-data"),
      FAKE_QWEN_MODE: mode,
      FAKE_QWEN_ARGS_FILE: fixture.argsFile,
    },
  });
  let output = null;
  if (result.stdout.trim()) output = JSON.parse(result.stdout.trim());
  return { ...fixture, result, output };
}

test("qwen runner accepts only a terminal success plus exit 0", () => {
  const run = runFake("normal");
  try {
    assert.equal(run.result.status, 0, JSON.stringify(run.output));
    assert.equal(run.output.status, "completed");
    assert.equal(run.output.rawOutput, "review");
    assert.equal(run.output.threadId, "fake-qwen-session");
    assert.equal(run.output.attempts.length, 1);
  } finally {
    cleanupDir(run.dir);
  }
});

test("qwen runner enforces sandbox and built-in budgets at the CLI boundary", () => {
  const run = runFake("read", ["--target", "draft.md"]);
  try {
    assert.equal(run.result.status, 0);
    const args = JSON.parse(fs.readFileSync(run.argsFile, "utf8"));
    assert.ok(args.includes("--safe-mode"));
    assert.ok(args.includes("--sandbox"));
    assert.deepEqual(args.slice(args.indexOf("--approval-mode"), args.indexOf("--approval-mode") + 2), [
      "--approval-mode",
      "plan",
    ]);
    assert.deepEqual(args.slice(args.indexOf("--core-tools"), args.indexOf("--core-tools") + 2), [
      "--core-tools",
      "read_file",
    ]);
    assert.equal(args[args.indexOf("--max-tool-calls") + 1], "4");
    assert.equal(args[args.indexOf("--max-session-turns") + 1], "30");
    assert.match(args[args.indexOf("--max-wall-time") + 1], /^\d+s$/);
  } finally {
    cleanupDir(run.dir);
  }
});

test("prompt-only review gives Qwen a zero tool-call budget", () => {
  const run = runFake("normal");
  try {
    assert.equal(run.result.status, 0);
    const args = JSON.parse(fs.readFileSync(run.argsFile, "utf8"));
    assert.equal(args[args.indexOf("--max-tool-calls") + 1], "0");
    assert.equal(args.includes("--core-tools"), false);
  } finally {
    cleanupDir(run.dir);
  }
});

test("qwen runner resumes the same session after a missing result", () => {
  const run = runFake("resume", [], { maxResumes: 2 });
  try {
    assert.equal(run.result.status, 0);
    assert.equal(run.output.status, "completed");
    assert.equal(run.output.rawOutput, "resumed review");
    assert.equal(run.output.attempts.length, 2);
    assert.equal(run.output.attempts[0].errorCode, "missing_result");
    assert.equal(run.output.attempts[1].sessionId, "fake-qwen-session");
  } finally {
    cleanupDir(run.dir);
  }
});

test("a timeout with a truncated JSON line resumes instead of failing parsing", () => {
  const run = runFake("timeout-resume", [], {
    maxResumes: 1,
    attemptTimeoutMs: 2000,
    idleTimeoutMs: 500,
    timeoutMs: 5000,
  });
  try {
    assert.equal(run.result.status, 0, JSON.stringify(run.output));
    assert.equal(run.output.status, "completed");
    assert.equal(run.output.attempts.length, 2);
    assert.equal(run.output.attempts[0].outcome, "incomplete");
    assert.equal(run.output.attempts[0].errorCode, "attempt_timeout");
    assert.equal(run.output.attempts[1].outcome, "completed");
  } finally {
    cleanupDir(run.dir);
  }
});

test("qwen runner allows read_file only for the exact declared target", () => {
  const fixture = setup();
  const result = spawnSync(process.execPath, [
    RUNNER,
    "--target", "draft.md",
    "--max-resumes", "0",
    "--attempt-timeout-ms", "5000",
    "--idle-timeout-ms", "5000",
    "--timeout-ms", "10000",
    "--",
    "Read and review draft.md.",
  ], {
    cwd: fixture.dir,
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${fixture.bin}${path.delimiter}${process.env.PATH}`,
      CLAUDE_PLUGIN_DATA: path.join(fixture.dir, "plugin-data"),
      FAKE_QWEN_MODE: "read",
    },
  });
  try {
    const output = JSON.parse(result.stdout.trim());
    assert.equal(result.status, 0);
    assert.equal(output.status, "completed");
    assert.equal(output.targetsVerified, true);
    assert.deepEqual(output.attempts[0].toolCalls, [{ name: "read_file", path: "draft.md" }]);
  } finally {
    cleanupDir(fixture.dir);
  }
});

for (const [mode, errorCode] of [
  ["malformed", "invalid_json"],
  ["forbidden", "forbidden_tool"],
  ["wrong-target", "forbidden_tool_path"],
  ["terminal-error", "qwen_terminal_error"],
  ["exit-mismatch", "exit_mismatch"],
]) {
  test(`qwen runner fails closed for ${mode}`, () => {
    const extra = mode === "wrong-target" ? ["--target", "draft.md"] : [];
    const run = runFake(mode, extra);
    try {
      assert.notEqual(run.result.status, 0);
      assert.equal(run.output.status, "failed");
      assert.equal(run.output.errorCode, errorCode);
      assert.equal(run.output.attempts.length, 1);
    } finally {
      cleanupDir(run.dir);
    }
  });
}

test("an empty terminal result is incomplete, not successful", () => {
  const run = runFake("empty");
  try {
    assert.notEqual(run.result.status, 0);
    assert.equal(run.output.status, "stalled");
    assert.equal(run.output.errorCode, "empty_result");
  } finally {
    cleanupDir(run.dir);
  }
});

test("hash mismatch fails even when Qwen emits a success result", () => {
  const run = runFake("mutate", ["--target", "draft.md"]);
  try {
    assert.notEqual(run.result.status, 0);
    assert.equal(run.output.status, "failed");
    assert.equal(run.output.errorCode, "hash_mismatch");
  } finally {
    cleanupDir(run.dir);
  }
});

test("raw stream capture is explicit and private", () => {
  const run = runFake("normal", ["--debug-capture"]);
  try {
    assert.equal(run.result.status, 0);
    const capture = run.output.attempts[0].debugCapture;
    assert.ok(capture.stdout.endsWith(".stdout.jsonl"));
    assert.ok(fs.existsSync(capture.stdout));
    assert.equal(fs.statSync(capture.stdout).mode & 0o777, 0o600);
    assert.match(fs.readFileSync(capture.stdout, "utf8"), /"type":"result"/);
  } finally {
    cleanupDir(run.dir);
  }
});

test("missing qwen binary produces an actionable failed job", () => {
  const dir = makeTempDir("qwen-runner-");
  try {
    const result = spawnSync(process.execPath, [
      RUNNER,
      "--max-resumes", "0",
      "--attempt-timeout-ms", "1000",
      "--idle-timeout-ms", "1000",
      "--timeout-ms", "2000",
      "--",
      "Review this prompt.",
    ], {
      cwd: dir,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: "/usr/bin:/bin",
        CLAUDE_PLUGIN_DATA: path.join(dir, "plugin-data"),
      },
    });
    const output = JSON.parse(result.stdout.trim());
    assert.notEqual(result.status, 0);
    assert.equal(output.errorCode, "qwen_not_found");
    assert.match(output.error, /qwen not found on PATH/);
  } finally {
    cleanupDir(dir);
  }
});

test("invalid targets still return the runner JSON contract", () => {
  const dir = makeTempDir("qwen-runner-");
  try {
    const result = spawnSync(process.execPath, [
      RUNNER,
      "--target", "../outside.md",
      "--",
      "Review the target.",
    ], {
      cwd: dir,
      encoding: "utf8",
      env: {
        ...process.env,
        CLAUDE_PLUGIN_DATA: path.join(dir, "plugin-data"),
      },
    });
    const output = JSON.parse(result.stdout.trim());
    assert.notEqual(result.status, 0);
    assert.equal(output.status, "failed");
    assert.equal(output.errorCode, "target_missing");
    assert.equal(output.jobId, null);
  } finally {
    cleanupDir(dir);
  }
});

function readBackgroundState(pluginData) {
  const stateRoot = path.join(pluginData, "state");
  if (!fs.existsSync(stateRoot)) return null;
  const workspaceDirs = fs.readdirSync(stateRoot);
  if (workspaceDirs.length !== 1) return null;
  const stateFile = path.join(stateRoot, workspaceDirs[0], "state.json");
  return fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : null;
}

test("a fast background review reaches terminal state without being clobbered", async () => {
  const fixture = setup();
  const pluginData = path.join(fixture.dir, "plugin-data");
  try {
    const parent = spawnSync(process.execPath, [
      RUNNER,
      "--background",
      "--max-resumes", "0",
      "--attempt-timeout-ms", "5000",
      "--idle-timeout-ms", "5000",
      "--timeout-ms", "10000",
      "--",
      "Review this prompt.",
    ], {
      cwd: fixture.dir,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fixture.bin}${path.delimiter}${process.env.PATH}`,
        CLAUDE_PLUGIN_DATA: pluginData,
        FAKE_QWEN_MODE: "normal",
      },
    });
    assert.equal(parent.status, 0);
    const queued = JSON.parse(parent.stdout.trim());
    assert.equal(queued.status, "queued");

    let job = null;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const state = readBackgroundState(pluginData);
      job = state?.jobs?.find((candidate) => candidate.id === queued.jobId) ?? null;
      if (job && !["queued", "running"].includes(job.status)) break;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    assert.equal(job?.status, "completed");
    assert.ok(job.completedAt);
  } finally {
    cleanupDir(fixture.dir);
  }
});

test("qwen preflight reports a local fake 0.21.0 binary as ready", () => {
  const fixture = setup();
  try {
    const result = spawnSync("/bin/bash", [PREFLIGHT], {
      cwd: fixture.dir,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fixture.bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
      },
    });
    const output = JSON.parse(result.stdout.trim());
    assert.equal(result.status, 0);
    assert.equal(output.status, "ok");
    assert.equal(output.qwen_version, "0.21.0");
    assert.equal(output.sandbox_provider, "sandbox-exec");
    assert.equal(output.capabilities.tool_allowlist, true);
    assert.equal(output.capabilities.exact_target_policy, true);
  } finally {
    cleanupDir(fixture.dir);
  }
});

test("qwen preflight rejects an unsupported semantic version", () => {
  const fixture = setup();
  try {
    const result = spawnSync("/bin/bash", [PREFLIGHT], {
      cwd: fixture.dir,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fixture.bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
        FAKE_QWEN_VERSION: "0.20.9",
      },
    });
    const output = JSON.parse(result.stdout.trim());
    assert.equal(output.status, "error");
    assert.equal(output.error_code, "qwen_version_unsupported");
  } finally {
    cleanupDir(fixture.dir);
  }
});
