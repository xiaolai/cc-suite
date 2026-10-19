import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const PLUGIN_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);
const SKILLS_DIR = path.join(PLUGIN_ROOT, "skills", "cc-suite");
const CONTRACT_DOC = path.join(
  PLUGIN_ROOT,
  "dev-docs",
  "delegation-failure-contract.md"
);

// Skills that delegate through claude_code / claude_code_reply. Each must carry
// the terminal-failure contract, so a call that fails is never reported as a
// result (issue #5).
const DELEGATING_SKILLS = [
  "claude-plan",
  "claude-review",
  "audit",
  "verify",
  "audit-fix",
  "claude-debug",
  "claude-implement",
];

// The contract text is authored once in dev-docs and embedded verbatim in each
// skill — a skill is read as one piece, and sending the model to fetch another
// file at the moment a call has already failed adds a step that can fail too.
// Reading the canonical copy from the doc here is what keeps the duplication
// honest: edit the doc, and every drifted copy is named by this test.
function canonicalBlock() {
  const doc = fs.readFileSync(CONTRACT_DOC, "utf8");
  const marker = "\n---\n\n";
  const at = doc.indexOf(marker);
  assert.notEqual(at, -1, "contract doc is missing its --- separator");
  return doc.slice(at + marker.length).trim();
}

test("the contract doc contains a usable canonical block", () => {
  const block = canonicalBlock();
  assert.ok(block.startsWith("## Failure Handling"), "block must start with its heading");
  // Guard the load-bearing clauses by name. If one is dropped from the doc the
  // skills would still match it verbatim and the suite would pass vacuously.
  for (const clause of [
    "terminal",
    "Never report a failed call as a result",
    "UNVERIFIED",
    "Do not recover on your own initiative",
    "claude_code_reply",
    "Preserve the session",
    "session_id",
    "may still be running",
    "partial workspace changes",
    "audit-fix",
  ]) {
    assert.ok(block.includes(clause), `canonical block is missing: ${clause}`);
  }
});

test("every delegating skill embeds the contract verbatim", () => {
  const block = canonicalBlock();
  const drifted = [];
  for (const skill of DELEGATING_SKILLS) {
    const file = path.join(SKILLS_DIR, skill, "SKILL.md");
    assert.ok(fs.existsSync(file), `missing skill: ${skill}`);
    if (!fs.readFileSync(file, "utf8").includes(block)) drifted.push(skill);
  }
  assert.deepEqual(
    drifted,
    [],
    `these skills do not match dev-docs/delegation-failure-contract.md: ${drifted.join(", ")}`
  );
});

// The list above is a snapshot, and a snapshot rots. Any skill that reaches for
// claude_code is making a delegated call that can fail the same way, so it needs
// the same contract — this catches the skill added next year, not just today's.
test("no skill delegates to claude_code without the contract", () => {
  const block = canonicalBlock();
  const missing = [];
  for (const entry of fs.readdirSync(SKILLS_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const file = path.join(SKILLS_DIR, entry.name, "SKILL.md");
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, "utf8");
    // Markdown table rows are dropped before matching. The `vocabulary` skill is
    // a terminology registry: it *defines* the term `delegate` in a table cell
    // that names the tool, without ever calling it. Keying on structure rather
    // than allow-listing that one skill by name means the exemption keeps
    // holding for the next registry-style skill, and still catches a real
    // delegating skill that happens to also contain tables.
    const prose = text
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("|"))
      .join("\n");
    const delegates = /mcp__claude-code__claude_code|claude_code_reply|claude_code\(/.test(prose);
    if (delegates && !text.includes(block)) missing.push(entry.name);
  }
  assert.deepEqual(
    missing,
    [],
    `skills delegate to claude_code but omit the failure contract: ${missing.join(", ")}`
  );
});
