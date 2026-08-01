import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

import {
  JsonlDecoder,
  QwenStreamError,
  consumeQwenEvent,
  createQwenStreamState,
  parseQwenJsonLine,
  removeStagedReview,
  snapshotReviewTargets,
  stageReviewTargets,
  verifyReviewTargets,
} from "../scripts/lib/qwen-stream.mjs";
import { cleanupDir, makeTempDir } from "./helpers.mjs";

function initEvent(sessionId = "session-1") {
  return {
    type: "system",
    subtype: "init",
    session_id: sessionId,
    permission_mode: "plan",
    tools: [],
    mcp_servers: [],
  };
}

function resultEvent(result = "review complete", sessionId = "session-1") {
  return {
    type: "result",
    subtype: "success",
    session_id: sessionId,
    is_error: false,
    result,
  };
}

test("JsonlDecoder preserves split UTF-8 and JSONL boundaries", () => {
  const decoder = new JsonlDecoder();
  const bytes = Buffer.from(`${JSON.stringify({ type: "assistant", text: "你好" })}\n`);
  const split = bytes.indexOf(Buffer.from("你")) + 1;
  assert.deepEqual(decoder.push(bytes.subarray(0, split)), []);
  const lines = decoder.push(bytes.subarray(split));
  assert.equal(lines.length, 1);
  assert.equal(JSON.parse(lines[0]).text, "你好");
  assert.deepEqual(decoder.finish(), []);
});

test("parseQwenJsonLine fails closed on malformed JSON", () => {
  assert.throws(
    () => parseQwenJsonLine("{not json"),
    (error) => error instanceof QwenStreamError && error.code === "invalid_json"
  );
});

test("a Plan-mode terminal result completes the stream state", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    consumeQwenEvent(state, {
      type: "assistant",
      session_id: "session-1",
      message: { content: [{ type: "text", text: "review complete" }] },
    });
    consumeQwenEvent(state, resultEvent());
    assert.equal(state.permissionMode, "plan");
    assert.equal(state.result, "review complete");
    assert.equal(state.resultSeen, true);
    assert.equal(state.sessionId, "session-1");
  } finally {
    cleanupDir(dir);
  }
});

test("init must explicitly confirm Plan mode", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    assert.throws(
      () => consumeQwenEvent(state, { ...initEvent(), permission_mode: "default" }),
      (error) => error.code === "wrong_permission_mode"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("a no-target review rejects every tool call", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    assert.throws(
      () => consumeQwenEvent(state, {
        type: "assistant",
        session_id: "session-1",
        message: {
          content: [{
            type: "tool_use",
            id: "tool-1",
            name: "read_file",
            input: { file_path: "README.md" },
          }],
        },
      }),
      (error) => error.code === "forbidden_tool"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("an exact target review allows only read_file on the declared real path", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    fs.writeFileSync(path.join(dir, "draft.md"), "draft\n");
    fs.writeFileSync(path.join(dir, "other.md"), "other\n");
    const targets = snapshotReviewTargets(dir, ["draft.md"]);
    const state = createQwenStreamState({ cwd: dir, targets });
    consumeQwenEvent(state, { ...initEvent(), tools: ["read_file"] });
    consumeQwenEvent(state, {
      type: "assistant",
      session_id: "session-1",
      message: {
        content: [{
          type: "tool_use",
          id: "tool-1",
          name: "read_file",
          input: { file_path: path.join(dir, "draft.md") },
        }],
      },
    });
    assert.equal(state.toolCalls.length, 1);
    assert.equal(state.toolCalls[0].realPath, fs.realpathSync(path.join(dir, "draft.md")));

    assert.throws(
      () => consumeQwenEvent(state, {
        type: "assistant",
        session_id: "session-1",
        message: {
          content: [{
            type: "tool_use",
            id: "tool-2",
            name: "read_file",
            input: { file_path: path.join(dir, "other.md") },
          }],
        },
      }),
      (error) => error.code === "forbidden_tool_path"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("a tool result with an id may only consume the pending call with that exact id", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    fs.writeFileSync(path.join(dir, "draft.md"), "draft\n");
    const targets = snapshotReviewTargets(dir, ["draft.md"]);
    const state = createQwenStreamState({ cwd: dir, targets });
    consumeQwenEvent(state, { ...initEvent(), tools: ["read_file"] });
    consumeQwenEvent(state, {
      type: "assistant",
      session_id: "session-1",
      message: {
        content: [{
          type: "tool_use",
          id: "tool-1",
          name: "read_file",
          input: { file_path: path.join(dir, "draft.md") },
        }],
      },
    });

    // A mismatched id must not consume the pending tool-1 call.
    assert.throws(
      () => consumeQwenEvent(state, { type: "tool_result", session_id: "session-1", tool_use_id: "tool-9" }),
      (error) => error.code === "unsolicited_tool_result"
    );
    // An id-less result must not consume the pending named call either.
    assert.throws(
      () => consumeQwenEvent(state, { type: "tool_result", session_id: "session-1" }),
      (error) => error.code === "unsolicited_tool_result"
    );
    // The exact id consumes the call; replaying it is unsolicited.
    consumeQwenEvent(state, { type: "tool_result", session_id: "session-1", tool_use_id: "tool-1" });
    assert.throws(
      () => consumeQwenEvent(state, { type: "tool_result", session_id: "session-1", tool_use_id: "tool-1" }),
      (error) => error.code === "unsolicited_tool_result"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("an id-less tool result may only consume an id-less validated call", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    fs.writeFileSync(path.join(dir, "draft.md"), "draft\n");
    const targets = snapshotReviewTargets(dir, ["draft.md"]);
    const state = createQwenStreamState({ cwd: dir, targets });
    consumeQwenEvent(state, { ...initEvent(), tools: ["read_file"] });
    consumeQwenEvent(state, {
      type: "assistant",
      session_id: "session-1",
      message: {
        parts: [{
          functionCall: {
            name: "read_file",
            args: { file_path: path.join(dir, "draft.md") },
          },
        }],
      },
    });

    // A result carrying an id must not consume the anonymous pending call.
    assert.throws(
      () => consumeQwenEvent(state, { type: "tool_result", session_id: "session-1", tool_use_id: "tool-9" }),
      (error) => error.code === "unsolicited_tool_result"
    );
    // The id-less result pairs with the anonymous call; a second one is unsolicited.
    consumeQwenEvent(state, { type: "tool_result", session_id: "session-1" });
    assert.throws(
      () => consumeQwenEvent(state, { type: "tool_result", session_id: "session-1" }),
      (error) => error.code === "unsolicited_tool_result"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("non-read tools are rejected even when a target is declared", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    fs.writeFileSync(path.join(dir, "draft.md"), "draft\n");
    const targets = snapshotReviewTargets(dir, ["draft.md"]);
    const state = createQwenStreamState({ cwd: dir, targets });
    consumeQwenEvent(state, { ...initEvent(), tools: ["read_file"] });
    assert.throws(
      () => consumeQwenEvent(state, {
        type: "assistant",
        session_id: "session-1",
        message: {
          content: [{
            type: "tool_use",
            id: "tool-1",
            name: "agent",
            input: { prompt: "hand this back" },
          }],
        },
      }),
      (error) => error.code === "forbidden_tool"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("init fails closed when Qwen exposes an unexpected tool", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    assert.throws(
      () => consumeQwenEvent(state, { ...initEvent(), tools: ["agent"] }),
      (error) => error.code === "tool_boundary_mismatch"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("target review requires read_file to be the only advertised tool", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    fs.writeFileSync(path.join(dir, "draft.md"), "draft\n");
    const targets = snapshotReviewTargets(dir, ["draft.md"]);
    const state = createQwenStreamState({ cwd: dir, targets });
    assert.throws(
      () => consumeQwenEvent(state, initEvent()),
      (error) => error.code === "tool_boundary_mismatch"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("init fails closed unless Safe Mode leaves the MCP server set empty", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    assert.throws(
      () => consumeQwenEvent(state, { ...initEvent(), mcp_servers: ["claude-code"] }),
      (error) => error.code === "tool_boundary_mismatch"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("session_start after init does not revalidate or replace the verified boundary", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    consumeQwenEvent(state, {
      type: "system",
      subtype: "session_start",
      session_id: "session-1",
    });
    assert.equal(state.toolBoundaryVerified, true);
  } finally {
    cleanupDir(dir);
  }
});

test("unknown top-level events fail closed", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    assert.throws(
      () => consumeQwenEvent(state, { type: "future_action", session_id: "session-1" }),
      (error) => error.code === "unknown_event"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("unclassified assistant content objects fail closed", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    assert.throws(
      () => consumeQwenEvent(state, {
        type: "assistant",
        session_id: "session-1",
        message: { content: [{ name: "read_file", input: { file_path: "draft.md" } }] },
      }),
      (error) => error.code === "unknown_content_block"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("session id changes fail closed", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent("session-1"));
    assert.throws(
      () => consumeQwenEvent(state, {
        type: "assistant",
        session_id: "session-2",
        message: { content: [{ type: "text", text: "wrong session" }] },
      }),
      (error) => error.code === "session_mismatch"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("duplicate terminal results fail closed", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    consumeQwenEvent(state, resultEvent());
    assert.throws(
      () => consumeQwenEvent(state, resultEvent()),
      (error) => error.code === "duplicate_result"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("a terminal result must be the final stream event", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const state = createQwenStreamState({ cwd: dir });
    consumeQwenEvent(state, initEvent());
    consumeQwenEvent(state, resultEvent());
    assert.throws(
      () => consumeQwenEvent(state, { type: "system", subtype: "heartbeat" }),
      (error) => error.code === "event_after_result"
    );
  } finally {
    cleanupDir(dir);
  }
});

test("target hashes provide independent before/after evidence", () => {
  const dir = makeTempDir("qwen-stream-");
  try {
    const target = path.join(dir, "draft.md");
    fs.writeFileSync(target, "before\n");
    const snapshots = snapshotReviewTargets(dir, ["draft.md"]);
    assert.deepEqual(verifyReviewTargets(snapshots), { ok: true, changed: [] });
    fs.writeFileSync(target, "after\n");
    const verified = verifyReviewTargets(snapshots);
    assert.equal(verified.ok, false);
    assert.deepEqual(verified.changed, [fs.realpathSync(target)]);
  } finally {
    cleanupDir(dir);
  }
});

test("review targets are copied into a private isolated stage", () => {
  const dir = makeTempDir("qwen-stream-");
  fs.mkdirSync(path.join(dir, "docs"));
  fs.writeFileSync(path.join(dir, "docs", "draft.md"), "private draft\n");
  const snapshots = snapshotReviewTargets(dir, ["docs/draft.md"]);
  const stage = stageReviewTargets(snapshots);
  try {
    assert.equal(stage.targets.length, 1);
    assert.equal(stage.targets[0].displayPath, path.join("docs", "draft.md"));
    assert.equal(fs.readFileSync(stage.targets[0].realPath, "utf8"), "private draft\n");
    assert.equal(fs.statSync(stage.root).mode & 0o777, 0o700);
    assert.equal(fs.statSync(stage.targets[0].realPath).mode & 0o777, 0o400);
    assert.notEqual(stage.targets[0].realPath, snapshots[0].realPath);
  } finally {
    removeStagedReview(stage);
    assert.equal(fs.existsSync(stage.root), false);
    cleanupDir(dir);
  }
});

test("targets cannot escape the workspace through relative paths", () => {
  const dir = makeTempDir("qwen-stream-");
  const outside = path.join(path.dirname(dir), `${path.basename(dir)}-outside.md`);
  fs.writeFileSync(outside, "outside\n");
  try {
    assert.throws(
      () => snapshotReviewTargets(dir, [outside]),
      (error) => error.code === "target_outside_workspace"
    );
  } finally {
    fs.rmSync(outside, { force: true });
    cleanupDir(dir);
  }
});
