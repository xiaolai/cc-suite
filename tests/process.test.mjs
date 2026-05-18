import test from "node:test";
import assert from "node:assert/strict";

import {
  runCommand,
  runCommandChecked,
  binaryAvailable,
  terminateProcessTree,
  formatCommandFailure,
} from "../scripts/lib/process.mjs";

test("runCommand captures stdout from echo", () => {
  const result = runCommand("echo", ["hello world"]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), "hello world");
  assert.equal(result.error, null);
});

test("runCommand captures exit code for false", () => {
  const result = runCommand("false");
  assert.notEqual(result.status, 0);
});

test("runCommandChecked throws on non-zero exit", () => {
  assert.throws(
    () => runCommandChecked("false"),
    (err) => err.message.includes("exit=")
  );
});

test("runCommandChecked returns result on success", () => {
  const result = runCommandChecked("echo", ["test"]);
  assert.equal(result.stdout.trim(), "test");
});

test("binaryAvailable returns true for node", () => {
  const result = binaryAvailable("node");
  assert.equal(result.available, true);
  assert.ok(result.detail);
});

test("binaryAvailable returns false for nonexistent binary", () => {
  const result = binaryAvailable("definitely-not-a-real-command-xyz");
  assert.equal(result.available, false);
});

test("terminateProcessTree returns attempted:false for non-finite PID", () => {
  const result = terminateProcessTree(NaN);
  assert.equal(result.attempted, false);
  assert.equal(result.delivered, false);
});

test("terminateProcessTree handles already-dead process", () => {
  // PID 999999999 almost certainly doesn't exist
  const result = terminateProcessTree(999999999);
  assert.equal(result.attempted, true);
  assert.equal(result.delivered, false);
});

test("formatCommandFailure formats with exit code", () => {
  const msg = formatCommandFailure({
    command: "npm",
    args: ["test"],
    status: 1,
    signal: null,
    stderr: "test failed",
    stdout: "",
  });
  assert.equal(msg, "npm test: exit=1: test failed");
});

test("formatCommandFailure formats with signal", () => {
  const msg = formatCommandFailure({
    command: "sleep",
    args: ["100"],
    status: null,
    signal: "SIGTERM",
    stderr: "",
    stdout: "",
  });
  assert.equal(msg, "sleep 100: signal=SIGTERM");
});
