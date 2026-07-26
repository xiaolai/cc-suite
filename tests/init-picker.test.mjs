import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const PLUGIN_ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  ".."
);
const INIT = fs.readFileSync(
  path.join(PLUGIN_ROOT, "commands", "init.md"),
  "utf8"
);

// The picker itself is prose the agent follows, so these lock in the parts that
// would silently change behaviour if edited away.

test("init drives the picker off real PATH detection, not a hardcoded list", () => {
  assert.match(
    INIT,
    /bridge_tools\.py"? --detect/,
    "init must probe what is installed rather than assume"
  );
  assert.match(
    INIT,
    /bridge_tools\.py"? --set-enabled/,
    "init must record the selection through the script, not by hand-editing"
  );
});

test("the bridge question is multi-select and pre-selects installed tools", () => {
  const step = INIT.slice(INIT.indexOf("Step 5b"), INIT.indexOf("Step 6"));
  assert.ok(step.length > 200, "Step 5b should exist and be substantive");
  assert.match(step, /multiSelect:\s*true/, "bridges are not mutually exclusive");
  assert.match(
    step,
    /[Pp]re-select every tool whose `installed` is true/,
    "the common case should be a single Enter"
  );
  assert.match(
    step,
    /china_note/,
    "China tier must be visible when choosing, not discovered later"
  );
});

test("Claude cannot be unticked", () => {
  const step = INIT.slice(INIT.indexOf("Step 5b"), INIT.indexOf("Step 6"));
  assert.match(
    step,
    /Claude is always bridged/i,
    "Claude is the source of truth the other bridges mirror from"
  );
});

test("every Codex-only step tells the agent to skip it when Codex is off", () => {
  // Each of these scripts writes into .codex/ or registers a Codex MCP server.
  // Running one in a project that did not select Codex is what the tool picker
  // exists to prevent, so each must carry an explicit skip instruction.
  const codexOnly = ["mcp_codex.sh", "mcp_claude.sh", "bridge_hooks.py"];
  const steps = INIT.split(/^### /m);

  for (const script of codexOnly) {
    const step = steps.find((s) => s.includes(script));
    assert.ok(step, `no init step runs ${script}`);
    assert.match(
      step,
      /\*\*Skip[^*]*\*\*/,
      `the step running ${script} must carry a bold skip instruction`
    );
    assert.match(
      step,
      /Codex/,
      `the skip condition for ${script} must name Codex`
    );
  }
});

test("the summary reports what was skipped instead of hiding it", () => {
  const summary = INIT.slice(INIT.indexOf("Step 12"));
  assert.match(
    summary,
    /Not bridged/,
    "a user should see which agents were left out and how to add them"
  );
  assert.match(
    summary,
    /bridge-tools/,
    "the summary should point at the command that changes the selection"
  );
});
