import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const PLUGIN_ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  ".."
);
const SKILLS_DIR = path.join(PLUGIN_ROOT, "skills", "cc-suite");

// Skills that either hand work back to Claude Code or mutate project state.
// bridge_skills.sh exposes every skill here to Codex through
// .agents/skills -> ../.claude/skills, so a Codex session that Claude itself
// spawned can see them. Left implicitly invocable, `$audit` matches an
// "audit this code" prompt and routes the audit back to Claude — collapsing the
// independent review into self-review. These must be explicit-only.
const EXPLICIT_ONLY = [
  "audit",
  "audit-fix",
  "verify",
  "claude-review",
  "claude-plan",
  "claude-implement",
  "claude-debug",
  "init",
  "repair",
  "diagnose",
];

// Passive reference skills. They inject knowledge and delegate nothing, so
// implicit invocation is the point — they must NOT carry the guard.
const IMPLICIT_ALLOWED = [
  "claude-code-conventions",
  "vocabulary",
  "agent-design",
];

function readPolicy(skill) {
  const policyPath = path.join(SKILLS_DIR, skill, "agents", "openai.yaml");
  if (!fs.existsSync(policyPath)) return null;
  return fs.readFileSync(policyPath, "utf8");
}

test("the guard list covers every cc-suite skill", () => {
  const onDisk = fs
    .readdirSync(SKILLS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
  const classified = [...EXPLICIT_ONLY, ...IMPLICIT_ALLOWED].sort();
  assert.deepEqual(
    onDisk,
    classified,
    "Every skill must be classified as explicit-only or implicit-allowed"
  );
});

test("delegating and mutating skills are explicit-only for Codex", () => {
  for (const skill of EXPLICIT_ONLY) {
    const policy = readPolicy(skill);
    assert.ok(
      policy,
      `Skill ${skill} must ship agents/openai.yaml to block implicit invocation`
    );
    assert.match(
      policy,
      /^policy:$/m,
      `Skill ${skill} openai.yaml must declare a policy block`
    );
    assert.match(
      policy,
      /^\s+allow_implicit_invocation:\s*false\s*$/m,
      `Skill ${skill} must set allow_implicit_invocation: false`
    );
  }
});

test("passive reference skills stay implicitly invocable", () => {
  for (const skill of IMPLICIT_ALLOWED) {
    const policy = readPolicy(skill);
    if (policy === null) continue;
    assert.doesNotMatch(
      policy,
      /allow_implicit_invocation:\s*false/,
      `Reference skill ${skill} should remain implicitly invocable`
    );
  }
});

test("the Codex call preamble forbids delegating the task back to Claude", () => {
  const partial = fs.readFileSync(
    path.join(PLUGIN_ROOT, "commands", "shared", "codex-call.md"),
    "utf8"
  );
  assert.match(
    partial,
    /Delegation boundary/,
    "codex-call.md must document a delegation-boundary preamble part"
  );
  assert.match(
    partial,
    /do not invoke workspace skills/i,
    "The preamble must tell Codex not to invoke workspace skills"
  );
  // The guard is worthless if it is described as optional.
  assert.match(
    partial,
    /Parts 1[-–]3 are always present/,
    "The delegation boundary must be an always-present preamble part"
  );
});
