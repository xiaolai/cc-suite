import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const PLUGIN_ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  ".."
);

function readCommand(name) {
  const filePath = path.join(PLUGIN_ROOT, "commands", `${name}.md`);
  return fs.readFileSync(filePath, "utf8");
}

function extractFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return {};
  const fm = {};
  for (const line of match[1].split("\n")) {
    const [key, ...rest] = line.split(":");
    if (key.trim()) fm[key.trim()] = rest.join(":").trim().replace(/^"(.*)"$/, "$1");
  }
  return fm;
}

const COMMANDS = [
  "audit",
  "audit-fix",
  "audit-plugin",
  "audit-skill",
  "audit-command",
  "audit-rules",
  "audit-agent",
  "audit-nlp",
  "bug-analyze",
  "cancel",
  "continue",
  "implement",
  "init",
  "preflight",
  "refresh-knowledge",
  "result",
  "review-plan",
  "setup",
  "status",
  "verify",
];

test("all expected command files exist", () => {
  for (const name of COMMANDS) {
    const filePath = path.join(PLUGIN_ROOT, "commands", `${name}.md`);
    assert.ok(
      fs.existsSync(filePath),
      `Missing command file: commands/${name}.md`
    );
  }
});

test("all commands have valid YAML frontmatter with description", () => {
  for (const name of COMMANDS) {
    const content = readCommand(name);
    const fm = extractFrontmatter(content);
    assert.ok(
      fm.description,
      `Command ${name} is missing description in frontmatter`
    );
    assert.ok(
      fm.description.length > 5,
      `Command ${name} has too short description: "${fm.description}"`
    );
  }
});

test("shared partials have user-invocable: false", () => {
  const sharedDir = path.join(PLUGIN_ROOT, "commands", "shared");
  const partials = fs.readdirSync(sharedDir).filter((f) => f.endsWith(".md"));
  assert.ok(partials.length >= 4, "Expected at least 4 shared partials");

  for (const name of partials) {
    const content = fs.readFileSync(path.join(sharedDir, name), "utf8");
    const fm = extractFrontmatter(content);
    assert.equal(
      fm["user-invocable"],
      "false",
      `Shared partial ${name} should have user-invocable: false`
    );
  }
});

test("background-capable commands mention --background flag", () => {
  const bgCommands = ["audit", "implement", "bug-analyze", "review-plan"];
  for (const name of bgCommands) {
    const content = readCommand(name);
    assert.ok(
      content.includes("--background"),
      `Command ${name} should support --background flag`
    );
  }
});

test("commands that call Codex reference codex-call.md", () => {
  const codexCommands = [
    "audit",
    "audit-fix",
    "bug-analyze",
    "implement",
    "review-plan",
    "verify",
  ];
  for (const name of codexCommands) {
    const content = readCommand(name);
    assert.ok(
      content.includes("codex-call.md"),
      `Command ${name} should reference codex-call.md`
    );
  }
});

test("commands that need models reference model-selection.md", () => {
  const modelCommands = [
    "audit",
    "audit-fix",
    "bug-analyze",
    "implement",
    "review-plan",
    "verify",
  ];
  for (const name of modelCommands) {
    const content = readCommand(name);
    assert.ok(
      content.includes("model-selection.md"),
      `Command ${name} should reference model-selection.md`
    );
  }
});

test("hooks.json exists and has correct structure", () => {
  const hooksPath = path.join(PLUGIN_ROOT, "hooks", "hooks.json");
  assert.ok(fs.existsSync(hooksPath), "hooks/hooks.json should exist");

  const hooks = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  assert.ok(hooks.hooks.SessionStart, "Missing SessionStart hook");
  assert.ok(hooks.hooks.SessionEnd, "Missing SessionEnd hook");
  assert.ok(hooks.hooks.Stop, "Missing Stop hook");

  // Check timeout values
  const startHook = hooks.hooks.SessionStart[0].hooks[0];
  assert.equal(startHook.timeout, 5);

  const stopHook = hooks.hooks.Stop[0].hooks[0];
  assert.equal(stopHook.timeout, 900);
});

test("audit-output schema exists and is valid JSON Schema", () => {
  const schemaPath = path.join(
    PLUGIN_ROOT,
    "schemas",
    "audit-output.schema.json"
  );
  assert.ok(fs.existsSync(schemaPath), "Schema file should exist");

  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  assert.equal(schema.type, "object");
  assert.ok(schema.required.includes("verdict"));
  assert.ok(schema.required.includes("findings"));
  assert.ok(schema.required.includes("summary"));
  assert.ok(schema.required.includes("next_steps"));
  assert.ok(
    schema.properties.findings.items.required.includes("dimension"),
    "Findings should require dimension field"
  );
});

test("plugin.json exists and has required fields", () => {
  const pluginPath = path.join(
    PLUGIN_ROOT,
    ".claude-plugin",
    "plugin.json"
  );
  const plugin = JSON.parse(fs.readFileSync(pluginPath, "utf8"));
  assert.ok(plugin.name);
  assert.ok(plugin.version);
  assert.ok(plugin.description);
});
