import test from "node:test";
import assert from "node:assert/strict";

import {
  runCommand,
  runCommandChecked,
  binaryAvailable,
  terminateProcessTree,
  formatCommandFailure,
  readProcessStartTime,
  processAlive,
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

test("runCommand preserves null status for signal-terminated child", () => {
  const result = runCommand("node", [
    "-e",
    'process.kill(process.pid, "SIGKILL")',
  ]);
  assert.equal(result.status, null);
  assert.equal(result.signal, "SIGKILL");
});

test("runCommandChecked throws on signal termination", () => {
  assert.throws(
    () =>
      runCommandChecked("node", ["-e", 'process.kill(process.pid, "SIGKILL")']),
    (err) => err.message.includes("signal=SIGKILL")
  );
});

test("binaryAvailable reports signal-terminated binary as unavailable", () => {
  const result = binaryAvailable("node", [
    "-e",
    'process.kill(process.pid, "SIGKILL")',
  ]);
  assert.equal(result.available, false);
  assert.ok(result.detail.includes("signal"));
});

test("terminateProcessTree returns attempted:false for non-finite PID", () => {
  const result = terminateProcessTree(NaN);
  assert.equal(result.attempted, false);
  assert.equal(result.delivered, false);
});

test("terminateProcessTree rejects zero, negative, and fractional PIDs", () => {
  for (const pid of [0, -0, -5, 1.5]) {
    const result = terminateProcessTree(pid);
    assert.equal(result.attempted, false, `pid ${pid} must not be signalled`);
    assert.equal(result.delivered, false);
  }
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

test("readProcessStartTime returns a stable token for a live process", () => {
  const first = readProcessStartTime(process.pid);
  assert.ok(first, "expected a start time for the current process");
  assert.equal(readProcessStartTime(process.pid), first);
});

test("readProcessStartTime returns null for invalid or dead pids", () => {
  assert.equal(readProcessStartTime(0), null);
  assert.equal(readProcessStartTime(-1), null);
  assert.equal(readProcessStartTime(999999999), null);
});

test("processAlive reflects liveness", () => {
  assert.equal(processAlive(process.pid), true);
  assert.equal(processAlive(999999999), false);
  assert.equal(processAlive(0), false);
});

test("processAlive reports a zombie as exited", async () => {
  const { spawn } = await import("node:child_process");
  const child = spawn(process.execPath, ["-e", "setTimeout(()=>{},60000)"], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(processAlive(child.pid), true);
  // Kill it without letting the event loop reap it: the child stays a zombie,
  // and kill(pid, 0) keeps succeeding even though the process has terminated.
  process.kill(child.pid, "SIGKILL");
  const { sleepSync } = await import("../scripts/lib/process.mjs");
  sleepSync(400);
  assert.equal(processAlive(child.pid), false, "a zombie must not count as alive");
});
