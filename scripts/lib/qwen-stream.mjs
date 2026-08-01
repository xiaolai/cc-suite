import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";

export class QwenStreamError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "QwenStreamError";
    this.code = code;
  }
}

function sha256Fd(fd) {
  const hash = createHash("sha256");
  const buffer = Buffer.allocUnsafe(64 * 1024);
  let bytesRead;
  do {
    bytesRead = fs.readSync(fd, buffer, 0, buffer.length, null);
    if (bytesRead > 0) hash.update(buffer.subarray(0, bytesRead));
  } while (bytesRead > 0);
  return hash.digest("hex");
}

function sha256File(filePath) {
  const fd = fs.openSync(filePath, "r");
  try {
    return sha256Fd(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function isInside(root, candidate) {
  const rel = path.relative(root, candidate);
  return rel === "" || (!rel.startsWith(`..${path.sep}`) && rel !== ".." && !path.isAbsolute(rel));
}

export function snapshotReviewTargets(cwd, targetArgs = []) {
  const root = fs.realpathSync.native(cwd);
  const seen = new Set();
  const snapshots = [];

  for (const rawTarget of targetArgs) {
    const absolute = path.resolve(root, rawTarget);
    let realPath;
    try {
      realPath = fs.realpathSync.native(absolute);
    } catch {
      throw new QwenStreamError("target_missing", `Review target does not exist: ${rawTarget}`);
    }

    if (!isInside(root, realPath)) {
      throw new QwenStreamError(
        "target_outside_workspace",
        `Review target must stay inside the workspace: ${rawTarget}`
      );
    }

    // Open the approved path once with no-follow semantics, then validate and
    // hash through that descriptor, so a concurrent rename/symlink swap cannot
    // make the stat or the hash inspect a different file than the one the
    // containment check above approved.
    let fd;
    try {
      fd = fs.openSync(realPath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    } catch {
      throw new QwenStreamError("target_missing", `Review target could not be opened: ${rawTarget}`);
    }
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile()) {
        throw new QwenStreamError("target_not_file", `Review target is not a file: ${rawTarget}`);
      }
      if (seen.has(realPath)) continue;
      seen.add(realPath);
      snapshots.push({
        requestedPath: rawTarget,
        displayPath: path.relative(root, realPath),
        realPath,
        sha256: sha256Fd(fd),
        size: stat.size,
      });
    } finally {
      fs.closeSync(fd);
    }
  }

  return snapshots;
}

export function stageReviewTargets(sourceTargets, parent = os.tmpdir()) {
  const stageParent = path.resolve(parent);
  const root = fs.mkdtempSync(path.join(stageParent, "cc-suite-qwen-review-"));
  fs.chmodSync(root, 0o700);

  try {
    const stagedPaths = [];
    for (const source of sourceTargets) {
      const stagedRelative = path.join("review-targets", source.displayPath);
      const destination = path.join(root, stagedRelative);
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.copyFileSync(source.realPath, destination, fs.constants.COPYFILE_EXCL);
      fs.chmodSync(destination, 0o400);
      stagedPaths.push(stagedRelative);
    }

    const targets = snapshotReviewTargets(root, stagedPaths);
    for (let index = 0; index < targets.length; index += 1) {
      if (targets[index].sha256 !== sourceTargets[index].sha256) {
        throw new QwenStreamError(
          "target_changed_during_stage",
          `Review target changed while its isolated copy was created: ${sourceTargets[index].displayPath}`
        );
      }
      targets[index].displayPath = sourceTargets[index].displayPath;
    }
    return { root, parent: stageParent, targets };
  } catch (error) {
    fs.rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

export function removeStagedReview(stage) {
  const root = path.resolve(stage.root);
  const parent = path.resolve(stage.parent);
  if (
    path.dirname(root) !== parent ||
    !path.basename(root).startsWith("cc-suite-qwen-review-")
  ) {
    throw new QwenStreamError("invalid_stage_path", "Refusing to remove an invalid Qwen review stage");
  }
  fs.rmSync(root, { recursive: true, force: true });
}

export function verifyReviewTargets(snapshots) {
  const changed = [];
  for (const before of snapshots) {
    try {
      const stat = fs.statSync(before.realPath);
      const sha256 = sha256File(before.realPath);
      if (!stat.isFile() || sha256 !== before.sha256) {
        changed.push(before.realPath);
      }
    } catch {
      changed.push(before.realPath);
    }
  }
  return { ok: changed.length === 0, changed };
}

// Cap the un-newline-terminated remainder so a child that streams bytes
// without ever emitting a newline (each chunk resets the runner's idle timer)
// cannot grow the buffer until the attempt deadline or an out-of-memory
// failure. 16M UTF-16 code units is far beyond any legitimate stream-json line.
const MAX_JSONL_BUFFER_LENGTH = 16 * 1024 * 1024;

export class JsonlDecoder {
  constructor() {
    this.decoder = new StringDecoder("utf8");
    this.buffer = "";
  }

  push(chunk) {
    this.buffer += this.decoder.write(chunk);
    const lines = this.#drain(false);
    if (this.buffer.length > MAX_JSONL_BUFFER_LENGTH) {
      throw new QwenStreamError(
        "stream_overflow",
        `Qwen emitted a stream-json line longer than ${MAX_JSONL_BUFFER_LENGTH} characters without a newline`
      );
    }
    return lines;
  }

  finish() {
    this.buffer += this.decoder.end();
    return this.#drain(true);
  }

  #drain(flush) {
    const lines = [];
    let newline;
    while ((newline = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, newline).replace(/\r$/, "");
      this.buffer = this.buffer.slice(newline + 1);
      if (line.trim()) lines.push(line);
    }
    if (flush && this.buffer.trim()) {
      lines.push(this.buffer.replace(/\r$/, ""));
      this.buffer = "";
    }
    return lines;
  }
}

export function parseQwenJsonLine(line) {
  try {
    const event = JSON.parse(line);
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      throw new Error("event is not an object");
    }
    return event;
  } catch (error) {
    throw new QwenStreamError(
      "invalid_json",
      `Qwen emitted malformed stream-json: ${error.message}`
    );
  }
}

function eventSessionId(event) {
  return event.session_id ?? event.sessionId ?? null;
}

function rememberSession(state, event) {
  const sessionId = eventSessionId(event);
  if (!sessionId) return;
  if (state.sessionId && state.sessionId !== sessionId) {
    throw new QwenStreamError(
      "session_mismatch",
      `Qwen changed session id from ${state.sessionId} to ${sessionId}`
    );
  }
  state.sessionId = sessionId;
}

function toolPathFromArgs(args) {
  if (!args || typeof args !== "object") return null;
  return args.file_path ?? args.path ?? args.absolute_path ?? null;
}

function validateReadTool(state, call) {
  const name = call?.name;
  if (name !== "read_file") {
    throw new QwenStreamError(
      "forbidden_tool",
      `Qwen attempted forbidden tool: ${name || "(unknown)"}`
    );
  }
  if (state.allowedTargets.size === 0) {
    throw new QwenStreamError(
      "forbidden_tool",
      "Qwen attempted read_file, but this review declared no file targets"
    );
  }

  const suppliedPath = toolPathFromArgs(call.args);
  if (typeof suppliedPath !== "string" || !suppliedPath.trim()) {
    throw new QwenStreamError("invalid_tool_args", "Qwen read_file omitted file_path");
  }

  const absolute = path.resolve(state.cwd, suppliedPath);
  let realPath;
  try {
    realPath = fs.realpathSync.native(absolute);
  } catch {
    throw new QwenStreamError(
      "forbidden_tool_path",
      `Qwen attempted to read an unavailable target: ${suppliedPath}`
    );
  }
  if (!state.allowedTargets.has(realPath)) {
    throw new QwenStreamError(
      "forbidden_tool_path",
      `Qwen attempted to read an undeclared target: ${suppliedPath}`
    );
  }

  const callId = call.id ?? null;
  state.toolCalls.push({
    id: callId,
    name,
    realPath,
    displayPath: state.allowedTargets.get(realPath).displayPath,
  });
  if (callId !== null) state.pendingToolCallIds.add(callId);
  else state.pendingAnonymousToolCalls += 1;
}

// Collect the tool-result correlation ids carried by a `tool_result` event or
// by tool_result/function_response blocks inside a `user` event. A `user`
// event carrying no tool-result payload yields no ids.
function toolResultIds(event) {
  if (event.type === "tool_result") {
    return [event.tool_use_id ?? event.toolUseId ?? event.id ?? null];
  }
  const message = event.message ?? {};
  const blocks = Array.isArray(message.content)
    ? message.content
    : Array.isArray(message.parts)
      ? message.parts
      : [];
  const ids = [];
  for (const block of blocks) {
    if (!block || typeof block !== "object") continue;
    if (block.type === "tool_result" || block.type === "function_response" || block.functionResponse) {
      ids.push(block.tool_use_id ?? block.toolUseId ?? block.id ?? null);
    }
  }
  return ids;
}

// Every tool result must pair exactly with the previously validated read_file
// call it answers: a result carrying an id may only consume the pending call
// with that same id, and an id-less result may only consume an id-less
// (anonymous) pending call. Cross-pairing would mean the correlation cannot be
// proven — a tool may have run without passing validateReadTool — so fail
// closed on any mismatch.
function consumeToolResults(state, event) {
  for (const id of toolResultIds(event)) {
    if (id !== null) {
      if (!state.pendingToolCallIds.has(id)) {
        throw new QwenStreamError(
          "unsolicited_tool_result",
          `Qwen emitted a tool result (${id}) with no matching validated read_file call`
        );
      }
      state.pendingToolCallIds.delete(id);
      continue;
    }
    if (state.pendingAnonymousToolCalls === 0) {
      throw new QwenStreamError(
        "unsolicited_tool_result",
        "Qwen emitted an id-less tool result with no matching id-less validated read_file call"
      );
    }
    state.pendingAnonymousToolCalls -= 1;
  }
}

function toolCallFromBlock(block) {
  if (!block || typeof block !== "object") return null;
  if (block.type === "tool_use" || block.type === "tool_call") {
    return {
      id: block.id ?? block.tool_use_id ?? block.toolCallId ?? null,
      name: block.name ?? block.tool_name ?? block.toolName,
      args: block.input ?? block.args ?? block.arguments ?? {},
    };
  }
  if (block.functionCall && typeof block.functionCall === "object") {
    return {
      id: block.functionCall.id ?? null,
      name: block.functionCall.name,
      args: block.functionCall.args ?? {},
    };
  }
  return null;
}

function inspectAssistant(state, event) {
  const message = event.message ?? {};
  const blocks = Array.isArray(message.content)
    ? message.content
    : Array.isArray(message.parts)
      ? message.parts
      : [];

  for (const block of blocks) {
    const call = toolCallFromBlock(block);
    if (call) {
      validateReadTool(state, call);
      continue;
    }
    if (typeof block === "string") continue;
    if (!block || typeof block !== "object") continue;
    if (block.type === "text" && typeof block.text === "string") continue;
    if (typeof block.text === "string" && !block.thought) continue;
    const kind = block.type ?? (block.thought ? "thinking" : null);
    if (
      kind === "thinking" ||
      kind === "tool_result" ||
      kind === "function_response" ||
      block.functionResponse
    ) {
      continue;
    }
    if (kind) {
      throw new QwenStreamError(
        "unknown_content_block",
        `Qwen emitted unsupported assistant content block: ${kind}`
      );
    }
    throw new QwenStreamError(
      "unknown_content_block",
      "Qwen emitted an unclassified assistant content object"
    );
  }
}

function validateInit(state, event) {
  if (state.initSeen) {
    throw new QwenStreamError("duplicate_init", "Qwen emitted more than one init event");
  }
  const mode = event.permission_mode ?? event.permissionMode;
  if (mode !== "plan") {
    throw new QwenStreamError(
      "wrong_permission_mode",
      `Qwen did not confirm Plan mode (received ${mode ?? "no permission_mode"})`
    );
  }

  if (!Array.isArray(event.mcp_servers) || event.mcp_servers.length !== 0) {
    throw new QwenStreamError(
      "tool_boundary_mismatch",
      "Qwen init did not confirm an empty MCP server set"
    );
  }
  if (!Array.isArray(event.tools) || event.tools.some((tool) => typeof tool !== "string")) {
    throw new QwenStreamError(
      "tool_boundary_mismatch",
      "Qwen init did not provide a valid tool list"
    );
  }

  const advertised = new Set(event.tools);
  const expected = state.allowedTargets.size > 0 ? new Set(["read_file"]) : new Set();
  const unexpected = [...advertised].filter((tool) => !expected.has(tool));
  const missing = [...expected].filter((tool) => !advertised.has(tool));
  if (unexpected.length > 0 || missing.length > 0 || advertised.size !== event.tools.length) {
    const details = [
      unexpected.length > 0 ? `unexpected=${unexpected.join(",")}` : null,
      missing.length > 0 ? `missing=${missing.join(",")}` : null,
      advertised.size !== event.tools.length ? "duplicate tool names" : null,
    ].filter(Boolean).join("; ");
    throw new QwenStreamError(
      "tool_boundary_mismatch",
      `Qwen init tool boundary mismatch${details ? `: ${details}` : ""}`
    );
  }

  state.initSeen = true;
  state.permissionMode = mode;
  state.advertisedTools = [...advertised];
  state.toolBoundaryVerified = true;
}

function inspectResult(state, event) {
  if (!state.initSeen) {
    throw new QwenStreamError("result_before_init", "Qwen emitted a result before Plan mode was verified");
  }
  if (state.resultSeen) {
    throw new QwenStreamError("duplicate_result", "Qwen emitted more than one terminal result event");
  }
  state.resultSeen = true;
  state.resultSubtype = event.subtype ?? null;
  state.isError = event.is_error ?? event.isError ?? null;
  state.usage = event.usage ?? null;

  if (state.resultSubtype !== "success" || state.isError !== false) {
    state.terminalError =
      typeof event.result === "string" && event.result.trim()
        ? event.result.trim()
        : `Qwen terminal result was ${state.resultSubtype ?? "unknown"} (is_error=${String(state.isError)})`;
    return;
  }
  if (typeof event.result !== "string" || !event.result.trim()) {
    state.emptyResult = true;
    return;
  }
  state.result = event.result.trim();
}

export function createQwenStreamState({ cwd, targets = [] }) {
  return {
    cwd: fs.realpathSync.native(cwd),
    allowedTargets: new Map(targets.map((target) => [target.realPath, target])),
    initSeen: false,
    permissionMode: null,
    advertisedTools: [],
    toolBoundaryVerified: false,
    sessionId: null,
    toolCalls: [],
    pendingToolCallIds: new Set(),
    pendingAnonymousToolCalls: 0,
    resultSeen: false,
    resultSubtype: null,
    isError: null,
    result: "",
    emptyResult: false,
    terminalError: null,
    usage: null,
    events: 0,
  };
}

export function consumeQwenEvent(state, event) {
  if (state.resultSeen) {
    if (event.type === "result") {
      throw new QwenStreamError("duplicate_result", "Qwen emitted more than one terminal result event");
    }
    throw new QwenStreamError(
      "event_after_result",
      `Qwen emitted ${event.type ?? "an unknown event"} after its terminal result`
    );
  }
  rememberSession(state, event);
  state.events += 1;

  switch (event.type) {
    case "system":
      if (event.subtype === "init") {
        validateInit(state, event);
      }
      return;
    case "assistant":
      if (!state.initSeen) {
        throw new QwenStreamError("assistant_before_init", "Qwen emitted assistant output before init");
      }
      inspectAssistant(state, event);
      return;
    case "user":
    case "tool_result":
      if (!state.initSeen) {
        throw new QwenStreamError("tool_result_before_init", "Qwen emitted tool output before init");
      }
      consumeToolResults(state, event);
      return;
    case "result":
      inspectResult(state, event);
      return;
    default:
      throw new QwenStreamError(
        "unknown_event",
        `Qwen emitted unsupported stream-json event type: ${event.type ?? "(missing)"}`
      );
  }
}

export function describeQwenEvent(event) {
  if (event.type === "system") return `event system/${event.subtype ?? "unknown"}`;
  if (event.type === "result") {
    return `event result/${event.subtype ?? "unknown"} is_error=${String(event.is_error ?? event.isError)}`;
  }
  if (event.type === "assistant") {
    const blocks = event.message?.content ?? event.message?.parts ?? [];
    const calls = Array.isArray(blocks)
      ? blocks.map(toolCallFromBlock).filter(Boolean).map((call) => call.name || "unknown")
      : [];
    return calls.length ? `event assistant tool=${calls.join(",")}` : "event assistant";
  }
  return `event ${event.type ?? "unknown"}`;
}
