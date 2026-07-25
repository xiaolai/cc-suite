import test from "node:test";
import assert from "node:assert/strict";

import {
  ERROR_RANK,
  cleanStderr,
  extractErrorEvent,
  unwrapErrorMessage,
  resolveFailureMessage,
} from "../scripts/lib/codex-errors.mjs";

// `codex exec` prints this to stderr on every run where stdin is not a TTY.
// The runner always hands the child /dev/null, so it is always present — and it
// is not an error.
const STDIN_NOTICE = "Reading additional input from stdin...";

test("cleanStderr drops the benign stdin notice entirely", () => {
  assert.equal(cleanStderr(STDIN_NOTICE), "");
  assert.equal(cleanStderr(`${STDIN_NOTICE}\n`), "");
  assert.equal(cleanStderr(""), "");
});

test("cleanStderr preserves a real clap usage error", () => {
  // The failure mode from cc-suite <= 0.2.18, which passed --approval-policy to
  // a `codex exec` that no longer accepts it. There are no JSONL events in this
  // case, so stderr is the only diagnostic.
  const usage = [
    "error: unexpected argument '--approval-policy' found",
    "",
    "Usage: codex exec [OPTIONS] [PROMPT]",
  ].join("\n");
  assert.equal(cleanStderr(`${STDIN_NOTICE}\n${usage}`), usage);
});

test("cleanStderr strips the notice from between real stderr lines", () => {
  const text = `first failure\n${STDIN_NOTICE}\nsecond failure`;
  assert.equal(cleanStderr(text), "first failure\nsecond failure");
});

test("extractErrorEvent ignores non-JSON and non-error events", () => {
  assert.equal(extractErrorEvent(""), null);
  assert.equal(extractErrorEvent("not json at all"), null);
  assert.equal(extractErrorEvent('{"type":"turn.started"}'), null);
  assert.equal(
    extractErrorEvent('{"type":"thread.started","thread_id":"abc"}'),
    null
  );
  assert.equal(
    extractErrorEvent(
      '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hi"}}'
    ),
    null
  );
});

test("extractErrorEvent reads each error-carrying event shape", () => {
  assert.deepEqual(
    extractErrorEvent(
      '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"metadata warning"}}'
    ),
    { rank: ERROR_RANK.item, message: "metadata warning" }
  );
  assert.deepEqual(
    extractErrorEvent('{"type":"error","message":"stream failure"}'),
    { rank: ERROR_RANK.error, message: "stream failure" }
  );
  assert.deepEqual(
    extractErrorEvent('{"type":"turn.failed","error":{"message":"turn died"}}'),
    { rank: ERROR_RANK.turn, message: "turn died" }
  );
});

test("extractErrorEvent ranks a terminal turn.failed above a warning item", () => {
  // A degraded-metadata notice arrives as an error *item* but is not fatal, so
  // it must never outrank the authoritative turn.failed event.
  const warning = extractErrorEvent(
    '{"type":"item.completed","item":{"type":"error","message":"Defaulting to fallback metadata"}}'
  );
  const fatal = extractErrorEvent(
    '{"type":"turn.failed","error":{"message":"real cause"}}'
  );
  assert.ok(fatal.rank > warning.rank);
});

test("unwrapErrorMessage surfaces the human message inside an API error blob", () => {
  // Codex forwards upstream API failures as a JSON string in `message`.
  const blob = JSON.stringify({
    type: "error",
    status: 400,
    error: {
      type: "invalid_request_error",
      message:
        "The 'gpt-5.1-codex' model is not supported when using Codex with a ChatGPT account.",
    },
  });
  assert.equal(
    unwrapErrorMessage(blob),
    "The 'gpt-5.1-codex' model is not supported when using Codex with a ChatGPT account."
  );
});

test("unwrapErrorMessage passes plain messages through untouched", () => {
  assert.equal(unwrapErrorMessage("plain failure"), "plain failure");
  assert.equal(unwrapErrorMessage("  padded  "), "padded");
  // Malformed JSON must not throw or be swallowed.
  assert.equal(unwrapErrorMessage('{"broken'), '{"broken');
  // An object with no message field is not a wrapper — keep the original.
  assert.equal(unwrapErrorMessage('{"status":500}'), '{"status":500}');
});

test("resolveFailureMessage reports the JSONL cause, not the stdin notice", () => {
  // Regression test for the reported bug: every failed run surfaced
  // "Reading additional input from stdin..." while the real cause sat unread in
  // the event stream.
  const event = extractErrorEvent(
    JSON.stringify({
      type: "turn.failed",
      error: {
        message: JSON.stringify({
          error: { message: "insufficient_quota: you exceeded your quota" },
        }),
      },
    })
  );
  const message = resolveFailureMessage({
    event,
    stderr: STDIN_NOTICE,
    code: 1,
  });
  assert.equal(message, "insufficient_quota: you exceeded your quota");
  assert.ok(!message.includes("stdin"));
});

test("resolveFailureMessage falls back to stderr when no event was emitted", () => {
  const usage = "error: unexpected argument '--approval-policy' found";
  assert.equal(
    resolveFailureMessage({
      event: null,
      stderr: `${STDIN_NOTICE}\n${usage}`,
      code: 2,
    }),
    usage
  );
});

test("resolveFailureMessage falls back to the exit code when nothing is usable", () => {
  assert.equal(
    resolveFailureMessage({ event: null, stderr: STDIN_NOTICE, code: 1 }),
    "exit 1"
  );
  assert.equal(resolveFailureMessage({ code: 7 }), "exit 7");
});

test("resolveFailureMessage keeps signal context when the child was killed", () => {
  assert.equal(
    resolveFailureMessage({ code: null, signal: "SIGKILL", stderr: STDIN_NOTICE }),
    "signal SIGKILL"
  );
  assert.equal(
    resolveFailureMessage({
      code: null,
      signal: "SIGTERM",
      stderr: `${STDIN_NOTICE}\nboom`,
    }),
    "signal SIGTERM: boom"
  );
});
