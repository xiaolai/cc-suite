// codex-errors.mjs — Turn a failed `codex exec` run into a usable message.
//
// `codex exec` reports terminal failures on its JSONL event stream, not on
// stderr. Meanwhile it writes one benign line to stderr on every run where
// stdin is not a TTY — and the runner always hands the child /dev/null. Reading
// the failure off stderr therefore reports that notice as the error and hides
// the real cause (bad model, expired auth, exhausted quota, upstream 4xx/5xx).
//
// These helpers read the cause off the event stream, unwrap the API error blob
// Codex nests inside it, and keep stderr as the fallback for failures that
// never reach the stream at all — an unknown CLI flag, for instance, which clap
// rejects before any event is emitted.

// Not an error: emitted whenever stdin is a pipe rather than a TTY.
const STDIN_NOTICE_LINE = /^[ \t]*Reading additional input from stdin\.\.\.[ \t]*$/;

// How authoritative each error-carrying event shape is. `item.completed` error
// items include non-fatal notices (degraded model metadata, for one), so they
// must never outrank the terminal events.
export const ERROR_RANK = Object.freeze({
  item: 1,
  error: 2,
  turn: 3,
});

// Depth cap for unwrapErrorMessage. Two levels covers the observed
// turn.failed -> JSON blob -> error.message nesting; the cap only exists so a
// pathological payload cannot spin.
const MAX_UNWRAP_DEPTH = 3;

/**
 * Strip the stdin notice from captured stderr, leaving real diagnostics intact.
 * @param {string} text
 * @returns {string} stderr with the notice removed, trimmed
 */
export function cleanStderr(text) {
  if (!text) return "";
  // Drop whole notice lines rather than blanking them in place, so no empty
  // line is left behind — and so real diagnostics keep their own formatting,
  // blank lines included (clap's usage output depends on them).
  return text
    .split("\n")
    .filter((line) => !STDIN_NOTICE_LINE.test(line))
    .join("\n")
    .trim();
}

/**
 * Read an error out of one JSONL event line.
 * @param {string} line
 * @returns {{rank: number, message: string} | null}
 */
export function extractErrorEvent(line) {
  if (!line || !line.trim()) return null;

  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return null; // partial or non-JSON line — nothing to read
  }
  if (!evt || typeof evt !== "object") return null;

  if (evt.type === "turn.failed" && typeof evt.error?.message === "string") {
    return { rank: ERROR_RANK.turn, message: evt.error.message };
  }
  if (evt.type === "error" && typeof evt.message === "string") {
    return { rank: ERROR_RANK.error, message: evt.message };
  }
  if (
    evt.type === "item.completed" &&
    evt.item?.type === "error" &&
    typeof evt.item.message === "string"
  ) {
    return { rank: ERROR_RANK.item, message: evt.item.message };
  }
  return null;
}

/**
 * Unwrap the JSON-encoded API error Codex nests inside a message field, so the
 * caller sees the human-readable sentence rather than the raw blob.
 * @param {string} message
 * @returns {string}
 */
export function unwrapErrorMessage(message) {
  if (typeof message !== "string") return "";
  let current = message.trim();

  for (let depth = 0; depth < MAX_UNWRAP_DEPTH; depth++) {
    if (!current.startsWith("{")) break;
    let parsed;
    try {
      parsed = JSON.parse(current);
    } catch {
      break; // not a wrapper after all — keep what we have
    }
    const inner = parsed?.error?.message ?? parsed?.message;
    if (typeof inner !== "string" || !inner.trim() || inner === current) break;
    current = inner.trim();
  }

  return current;
}

/**
 * Compose the message reported for a failed run. The event stream wins; stderr
 * covers failures that never produced events; the exit code is the last resort.
 * @param {object} opts
 * @param {{rank: number, message: string} | null} [opts.event] highest-ranked error event seen
 * @param {string} [opts.stderr] raw captured stderr
 * @param {number | null} [opts.code] child exit code, null when signalled
 * @param {string | null} [opts.signal] terminating signal, when code is null
 * @returns {string}
 */
export function resolveFailureMessage({
  event = null,
  stderr = "",
  code = null,
  signal = null,
} = {}) {
  const fromEvent = event ? unwrapErrorMessage(event.message) : "";
  const detail = fromEvent || cleanStderr(stderr);

  if (code === null) {
    return detail ? `signal ${signal}: ${detail}` : `signal ${signal}`;
  }
  return detail || `exit ${code}`;
}
