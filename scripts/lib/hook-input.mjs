import fs from "node:fs";

// Claude Code spawns a hook process and then writes the JSON payload to its
// stdin. On macOS that pipe can arrive non-blocking, so a read issued before
// the parent's write fails with EAGAIN instead of waiting — fs.readFileSync(0)
// turns that race into a startup crash. Retry EAGAIN with a real sleep, and
// keep reading until EOF so a payload split across pipe writes is reassembled
// rather than truncated at the first chunk.
const RETRY_SLEEP_MS = 5;
// Must stay well under the 5s hooks.json timeout on the session-lifecycle
// hooks. The spawn-vs-write race resolves in milliseconds; hitting this cap
// means the parent hung, which deserves a loud failure, not a longer wait.
const MAX_WAIT_MS = 2000;
const CHUNK_SIZE = 64 * 1024;

const SLEEP_SIGNAL = new Int32Array(new SharedArrayBuffer(4));

function sleep(ms) {
  Atomics.wait(SLEEP_SIGNAL, 0, 0, ms);
}

export function readStdinSync(options = {}) {
  const readImpl = options.readImpl ?? fs.readSync;
  const sleepImpl = options.sleepImpl ?? sleep;
  const maxWaitMs = options.maxWaitMs ?? MAX_WAIT_MS;

  const chunks = [];
  const buffer = Buffer.alloc(CHUNK_SIZE);
  let waitedMs = 0;
  for (;;) {
    let bytesRead;
    try {
      bytesRead = readImpl(0, buffer, 0, buffer.length, null);
    } catch (error) {
      if (error?.code === "EAGAIN") {
        if (waitedMs >= maxWaitMs) {
          throw new Error(
            `stdin produced no data within ${maxWaitMs}ms (EAGAIN); hook payload never arrived`
          );
        }
        sleepImpl(RETRY_SLEEP_MS);
        waitedMs += RETRY_SLEEP_MS;
        continue;
      }
      // Windows reports a closed pipe as an EOF error rather than 0 bytes.
      if (error?.code === "EOF") break;
      throw error;
    }
    if (bytesRead === 0) break;
    chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
  }
  return Buffer.concat(chunks).toString("utf8");
}

export function readHookInput(options = {}) {
  const raw = readStdinSync(options).trim();
  if (!raw) return {};
  return JSON.parse(raw);
}
