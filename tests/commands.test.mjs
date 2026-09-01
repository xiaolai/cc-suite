import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const PLUGIN_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
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
  "agy-preflight",
  "agy",
  "grok-preflight",
  "grok",
  "qwen-preflight",
  "qwen-review",
  "bridge-tools",
  "migrate-google",
  "codex-preflight",
  "refresh-knowledge",
  "result",
  "review-plan",
  "setup",
  "status",
  "sync-mcp",
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

test("sync-mcp documents the Claude-to-Codex bridge", () => {
  const content = readCommand("sync-mcp");
  assert.ok(content.includes("scripts/bridge_mcp.sh"));
  assert.ok(content.includes("^[a-zA-Z0-9_-]+$"));
  assert.ok(content.includes("restart Codex"));
});

test("agy command uses the Antigravity runner without an effort picker", () => {
  const content = readCommand("agy");
  assert.ok(content.includes("scripts/agy-runner.mjs"));
  assert.ok(content.includes("scripts/agy-preflight.sh"));
  assert.ok(content.includes("Do not ask for a reasoning-effort setting"));
});

test("qwen review command is Plan-only and uses the supervised runner", () => {
  const content = readCommand("qwen-review");
  assert.ok(content.includes("scripts/qwen-runner.mjs"));
  assert.ok(content.includes("scripts/qwen-preflight.sh"));
  assert.ok(content.includes("--approval-mode plan"));
  assert.ok(content.includes("--target"));
  assert.ok(content.includes("critique, not evidence"));
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
  const bgCommands = ["audit", "implement", "bug-analyze", "review-plan", "qwen-review"];
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

test("tools needing a skills symlink are documented as exceptions", () => {
  // bridge-tools.md used to claim all four registry tools read the shared
  // skills tree natively, while its own table showed qwen getting a symlink.
  // Any tool whose profile carries skills_symlink does NOT read the shared
  // tree and must be called out, or users silently lose their skills.
  const registry = fs.readFileSync(
    path.join(PLUGIN_ROOT, "scripts", "bridge_tools.py"),
    "utf8"
  );
  // Bound the slice at the dict's closing brace (a lone "}" at column 0).
  // Running to end-of-file would sweep in the emitter code that *implements*
  // skills_symlink and mark every trailing profile as needing one.
  const profilesStart = registry.indexOf("PROFILES: dict[str, dict] = {");
  assert.notEqual(profilesStart, -1, "Expected a PROFILES registry");
  const rest = registry.slice(profilesStart);
  const closeAt = rest.search(/^\}$/m);
  assert.notEqual(closeAt, -1, "Expected PROFILES to be brace-terminated");
  const profiles = rest.slice(0, closeAt);

  // Profile keys sit at four-space indent; slice each one up to the next.
  const keyRe = /^ {4}"([a-z0-9_-]+)": \{$/gm;
  const marks = [...profiles.matchAll(keyRe)].map((m) => ({
    name: m[1],
    index: m.index,
  }));
  assert.ok(marks.length >= 4, "Expected to parse the tool-profile registry");

  const needSymlink = marks.filter(({ index }, i) => {
    const end = i + 1 < marks.length ? marks[i + 1].index : profiles.length;
    return profiles.slice(index, end).includes("skills_symlink");
  });
  assert.ok(
    needSymlink.length > 0,
    "Expected at least one profile to declare skills_symlink"
  );

  const doc = fs.readFileSync(
    path.join(PLUGIN_ROOT, "commands", "bridge-tools.md"),
    "utf8"
  );
  // Check the body only. The frontmatter description also names the exception,
  // and matching against it would let the body lose its explanation unnoticed.
  const body = doc.replace(/^---\n[\s\S]*?\n---\n/, "");
  assert.doesNotMatch(
    body,
    /All four read `AGENTS\.md`/,
    "bridge-tools.md must not claim every tool reads the shared skills tree"
  );
  for (const { name } of needSymlink) {
    assert.match(
      body,
      new RegExp(`\`\\.${name}/skills/?\``),
      `bridge-tools.md must document the .${name}/skills symlink`
    );
    assert.match(
      body,
      new RegExp(`\\*\\*${name} [^*]*does not\\*\\*`, "i"),
      `bridge-tools.md body must call out ${name} as not reading the shared tree`
    );
  }
});

test("package.json and plugin.json agree on name and version", () => {
  // Nothing enforced this before, and the two drifted four releases apart
  // (package.json 0.9.0 vs plugin.json 0.11.0). plugin.json is the release
  // artifact and therefore the source of truth.
  const plugin = JSON.parse(
    fs.readFileSync(
      path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"),
      "utf8"
    )
  );
  const pkg = JSON.parse(
    fs.readFileSync(path.join(PLUGIN_ROOT, "package.json"), "utf8")
  );
  assert.equal(pkg.name, plugin.name);
  assert.equal(
    pkg.version,
    plugin.version,
    "Bump package.json alongside .claude-plugin/plugin.json"
  );
  assert.match(plugin.version, /^\d+\.\d+\.\d+$/, "Version must be semver");
});
