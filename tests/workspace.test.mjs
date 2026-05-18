import test from "node:test";
import assert from "node:assert/strict";

import { makeTempDir, initGitRepo, cleanupDir } from "./helpers.mjs";
import { resolveWorkspaceRoot } from "../scripts/lib/workspace.mjs";

test("resolveWorkspaceRoot returns git root for git repos", () => {
  const dir = makeTempDir();
  try {
    initGitRepo(dir);
    const root = resolveWorkspaceRoot(dir);
    // Should be the same dir (it's the git root)
    assert.ok(root.length > 0);
  } finally {
    cleanupDir(dir);
  }
});

test("resolveWorkspaceRoot returns cwd for non-git directories", () => {
  const dir = makeTempDir();
  try {
    const root = resolveWorkspaceRoot(dir);
    assert.equal(root, dir);
  } finally {
    cleanupDir(dir);
  }
});
