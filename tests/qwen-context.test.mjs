import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

import { makeTempDir, cleanupDir } from "./helpers.mjs";

const PLUGIN_ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  ".."
);
const SCRIPT = path.join(PLUGIN_ROOT, "scripts", "bridge_tools.py");
const SETTINGS = ".qwen/settings.json";

// Drive the real functions in-process rather than reimplementing their logic.
function callPython(body) {
  const src = [
    "import json, sys, pathlib",
    `sys.path.insert(0, ${JSON.stringify(path.join(PLUGIN_ROOT, "scripts"))})`,
    "import bridge_tools as bt",
    'SPEC = bt.PROFILES["qwen"]["context_files"]',
    body,
  ].join("\n");
  const res = spawnSync("python3", ["-c", src], { encoding: "utf8" });
  if (res.status !== 0) {
    throw new Error(`python failed: ${res.stderr || res.stdout}`);
  }
  return res.stdout;
}

function withSettings(initial, body) {
  const dir = makeTempDir("qwen-ctx-");
  const file = path.join(dir, SETTINGS);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (initial !== null) {
    fs.writeFileSync(file, JSON.stringify(initial, null, 2) + "\n");
  }
  try {
    const out = callPython(
      `p = pathlib.Path(${JSON.stringify(file)})\n${body}`
    );
    const doc = fs.existsSync(file)
      ? JSON.parse(fs.readFileSync(file, "utf8"))
      : null;
    return { doc, out };
  } finally {
    cleanupDir(dir);
  }
}

const ENSURE = 'print(bt.ensure_context_files(p, SPEC))';
const UNDO = 'bt._unbridge_context_files(p, SPEC)';

test("qwen profile declares the AGENTS.md context fix", () => {
  const src = fs.readFileSync(SCRIPT, "utf8");
  assert.match(
    src,
    /"context_files":\s*\{"key":\s*\["context",\s*"fileName"\]/,
    "qwen must declare context.fileName — the key qwen-code actually reads"
  );
});

test("the design doc does not claim qwen reads AGENTS.md natively", () => {
  // This exact claim ("free on v0.11.1+, AGENTS.md is a default context
  // filename") is why the qwen profile shipped without context-file handling
  // and silently dropped every bridged project's AGENTS.md until v0.12.0. The
  // upstream docs still read that way, so guard the correction.
  const doc = fs.readFileSync(
    path.join(PLUGIN_ROOT, "dev-docs", "supporting-more-coding-agents.md"),
    "utf8"
  );
  const qwenSection = doc.slice(
    doc.indexOf("### 6.4 Qwen Code"),
    doc.indexOf("### 6.5")
  );
  assert.ok(qwenSection.length > 200, "the Qwen section should exist");
  assert.match(
    qwenSection,
    /context\.fileName/,
    "the Qwen section must name the setting the bridge writes"
  );
  assert.doesNotMatch(
    qwenSection,
    /^- \*\*Instructions:\*\* \*\*free\*\*/m,
    "Qwen's instruction bridging is not free — it needs context.fileName"
  );
});

test("a project with no qwen settings gets AGENTS.md first", () => {
  // qwen-code 0.21.0 defaults to ["QWEN.md"] when unset, so AGENTS.md would
  // otherwise never be read.
  const { doc } = withSettings(null, ENSURE);
  assert.deepEqual(doc.context.fileName, ["AGENTS.md", "QWEN.md"]);
});

test("existing mcpServers and unrelated keys survive the edit", () => {
  const { doc } = withSettings(
    { mcpServers: { foo: { command: "x" } }, theme: "dark" },
    ENSURE
  );
  assert.deepEqual(doc.context.fileName, ["AGENTS.md", "QWEN.md"]);
  assert.deepEqual(doc.mcpServers, { foo: { command: "x" } });
  assert.equal(doc.theme, "dark");
});

test("a user's own context list is extended, never replaced", () => {
  const { doc } = withSettings(
    { context: { fileName: ["HOUSE-RULES.md"], other: 1 } },
    ENSURE
  );
  assert.deepEqual(doc.context.fileName, [
    "AGENTS.md",
    "QWEN.md",
    "HOUSE-RULES.md",
  ]);
  assert.equal(doc.context.other, 1, "sibling context keys must survive");
});

test("a string value is upgraded to a list without losing it", () => {
  const { doc } = withSettings({ context: { fileName: "QWEN.md" } }, ENSURE);
  assert.deepEqual(doc.context.fileName, ["AGENTS.md", "QWEN.md"]);
});

test("re-running is idempotent and reports no change", () => {
  const dir = makeTempDir("qwen-ctx-");
  const file = path.join(dir, SETTINGS);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  try {
    const p = JSON.stringify(file);
    const first = callPython(
      `p = pathlib.Path(${p})\nprint(bt.ensure_context_files(p, SPEC))`
    );
    const after1 = fs.readFileSync(file, "utf8");
    const second = callPython(
      `p = pathlib.Path(${p})\nprint(bt.ensure_context_files(p, SPEC))`
    );
    assert.equal(fs.readFileSync(file, "utf8"), after1, "file must not churn");
    assert.match(first, /context\.fileName = /);
    assert.match(second, /already includes AGENTS\.md/);
  } finally {
    cleanupDir(dir);
  }
});

test("unbridge removes what cc-suite added and drops the empty wrapper", () => {
  const { doc } = withSettings(null, `${ENSURE}\n${UNDO}`);
  assert.equal(
    doc.context,
    undefined,
    "an emptied context wrapper should not be left behind"
  );
});

test("unbridge keeps the user's own entries", () => {
  const { doc } = withSettings(
    { context: { fileName: ["HOUSE-RULES.md"] } },
    `${ENSURE}\n${UNDO}`
  );
  assert.deepEqual(doc.context.fileName, ["HOUSE-RULES.md"]);
});

test("unbridge leaves a reordered list alone", () => {
  // Once the user has rearranged the list it is theirs, not ours to prune.
  const { doc } = withSettings(
    { context: { fileName: ["MINE.md", "AGENTS.md", "QWEN.md"] } },
    UNDO
  );
  assert.deepEqual(doc.context.fileName, ["MINE.md", "AGENTS.md", "QWEN.md"]);
});

test("unbridge is a no-op when there is nothing to undo", () => {
  const { doc } = withSettings({ mcpServers: {} }, UNDO);
  assert.deepEqual(doc, { mcpServers: {} });
});
