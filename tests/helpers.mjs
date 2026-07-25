import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export function makeTempDir(prefix = "codex-toolkit-test-") {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export function writeExecutable(filePath, source) {
  fs.writeFileSync(filePath, source, { encoding: "utf8", mode: 0o755 });
}

export function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: "utf8",
    input: options.input,
  });
}

export function initGitRepo(cwd) {
  run("git", ["init", "-b", "main"], { cwd });
  run("git", ["config", "user.name", "Codex Toolkit Tests"], { cwd });
  run("git", ["config", "user.email", "tests@example.com"], { cwd });
  run("git", ["config", "commit.gpgsign", "false"], { cwd });
  run("git", ["config", "tag.gpgsign", "false"], { cwd });
}

export function cleanupDir(dirPath) {
  if (dirPath && fs.existsSync(dirPath)) {
    fs.rmSync(dirPath, { recursive: true, force: true });
  }
}

// Environment variables that change where state lives or which jobs are
// visible. Both are set inside a cc-suite-enabled Claude Code session — the
// exact environment a maintainer runs the suite in — so a test that reads them
// ambiently passes on CI and fails on a developer's machine:
//
//   CLAUDE_PLUGIN_DATA      reroutes resolveStateDir away from the temp fallback
//   CODEX_TOOLKIT_SESSION_ID  makes job queries drop every job lacking that id
//
// Tests must declare the values they depend on rather than inherit them.
export const AMBIENT_STATE_ENV = Object.freeze([
  "CLAUDE_PLUGIN_DATA",
  "CODEX_TOOLKIT_SESSION_ID",
]);

/**
 * Clear every ambient var in AMBIENT_STATE_ENV, then apply `overrides`.
 * Pass a string to set a var, undefined/null to keep it cleared.
 * @param {Record<string, string | undefined | null>} [overrides]
 * @returns {() => void} restores the previous environment exactly
 */
export function isolateEnv(overrides = {}) {
  const keys = new Set([...AMBIENT_STATE_ENV, ...Object.keys(overrides)]);
  const saved = new Map();

  for (const key of keys) {
    saved.set(key, Object.hasOwn(process.env, key) ? process.env[key] : null);
    delete process.env[key];
  }
  for (const [key, value] of Object.entries(overrides)) {
    if (value != null) process.env[key] = value;
  }

  return function restore() {
    for (const [key, value] of saved) {
      if (value === null) delete process.env[key];
      else process.env[key] = value;
    }
  };
}

/**
 * Run `fn` with a hermetic environment, restoring it afterwards even on throw.
 * @template T
 * @param {Record<string, string | undefined | null>} overrides
 * @param {() => T} fn
 * @returns {T}
 */
export function withIsolatedEnv(overrides, fn) {
  const restore = isolateEnv(overrides);
  try {
    return fn();
  } finally {
    restore();
  }
}
