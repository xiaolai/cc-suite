import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";

import { readStdinSync, readHookInput } from "../scripts/lib/hook-input.mjs";

// Builds a readImpl that replays the given steps in order: a string is a data
// chunk, 0 is EOF, and { err } throws an error with that code. Steps past the
// end of the list read as EOF.
function scriptedRead(steps) {
  let index = 0;
  return (fd, buffer) => {
    const step = index < steps.length ? steps[index++] : 0;
    if (typeof step === "object" && step !== null) {
      const error = new Error(step.err);
      error.code = step.err;
      throw error;
    }
    if (step === 0) return 0;
    const data = Buffer.from(step);
    data.copy(buffer);
    return data.length;
  };
}

const noSleep = () => {};

test("readStdinSync retries EAGAIN until the payload arrives", () => {
  let sleeps = 0;
  const result = readStdinSync({
    readImpl: scriptedRead([{ err: "EAGAIN" }, { err: "EAGAIN" }, '{"a":1}', 0]),
    sleepImpl: () => {
      sleeps += 1;
    },
  });
  assert.equal(result, '{"a":1}');
  assert.equal(sleeps, 2);
});

test("readStdinSync reassembles a payload split across reads", () => {
  const result = readStdinSync({
    readImpl: scriptedRead(['{"session_id":', '"s-1"}', 0]),
    sleepImpl: noSleep,
  });
  assert.equal(result, '{"session_id":"s-1"}');
});

test("readStdinSync handles EAGAIN between chunks", () => {
  const result = readStdinSync({
    readImpl: scriptedRead(["part-one ", { err: "EAGAIN" }, "part-two", 0]),
    sleepImpl: noSleep,
  });
  assert.equal(result, "part-one part-two");
});

test("readStdinSync throws after the EAGAIN wait budget is exhausted", () => {
  let sleeps = 0;
  assert.throws(
    () =>
      readStdinSync({
        readImpl: () => {
          const error = new Error("EAGAIN");
          error.code = "EAGAIN";
          throw error;
        },
        sleepImpl: () => {
          sleeps += 1;
        },
        maxWaitMs: 20,
      }),
    (err) => err.message.includes("EAGAIN")
  );
  assert.equal(sleeps, 4); // 20ms budget / 5ms per retry
});

test("readStdinSync treats an EOF error as end of input", () => {
  const result = readStdinSync({
    readImpl: scriptedRead(["windows-pipe", { err: "EOF" }]),
    sleepImpl: noSleep,
  });
  assert.equal(result, "windows-pipe");
});

test("readStdinSync propagates unexpected errors", () => {
  assert.throws(
    () =>
      readStdinSync({
        readImpl: scriptedRead([{ err: "EBADF" }]),
        sleepImpl: noSleep,
      }),
    (err) => err.code === "EBADF"
  );
});

test("readHookInput returns {} for empty stdin", () => {
  const result = readHookInput({ readImpl: scriptedRead([0]), sleepImpl: noSleep });
  assert.deepEqual(result, {});
});

test("readHookInput parses the JSON payload", () => {
  const result = readHookInput({
    readImpl: scriptedRead(['  {"cwd":"/tmp"}\n', 0]),
    sleepImpl: noSleep,
  });
  assert.deepEqual(result, { cwd: "/tmp" });
});

test("readHookInput reads a payload written late and in chunks over a real pipe", async () => {
  const moduleUrl = new URL("../scripts/lib/hook-input.mjs", import.meta.url).href;
  const script = `import(${JSON.stringify(
    moduleUrl
  )}).then((m) => process.stdout.write(JSON.stringify(m.readHookInput())));`;

  const child = spawn(process.execPath, ["-e", script], {
    stdio: ["pipe", "pipe", "inherit"],
  });

  const payload = '{"session_id":"s-123","hook_event_name":"Stop"}';
  setTimeout(() => child.stdin.write(payload.slice(0, 20)), 50);
  setTimeout(() => {
    child.stdin.write(payload.slice(20));
    child.stdin.end();
  }, 100);

  let stdout = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  const exitCode = await new Promise((resolve) => child.on("close", resolve));

  assert.equal(exitCode, 0);
  assert.deepEqual(JSON.parse(stdout), JSON.parse(payload));
});
