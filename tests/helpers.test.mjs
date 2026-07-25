import test from "node:test";
import assert from "node:assert/strict";

import {
  AMBIENT_STATE_ENV,
  isolateEnv,
  withIsolatedEnv,
  makeTempDir,
  cleanupDir,
} from "./helpers.mjs";
import { upsertJob } from "../scripts/lib/state.mjs";
import { buildStatusSnapshot, resolveResultJob } from "../scripts/lib/job-control.mjs";

test("isolateEnv clears every ambient state variable", () => {
  const restore = isolateEnv();
  try {
    for (const key of AMBIENT_STATE_ENV) {
      assert.equal(process.env[key], undefined, `${key} should be cleared`);
    }
  } finally {
    restore();
  }
});

test("isolateEnv restores prior values exactly, including absence", () => {
  const present = AMBIENT_STATE_ENV[0];
  const absent = AMBIENT_STATE_ENV[1];
  const sentinel = "sentinel-value";

  const outer = isolateEnv({ [present]: sentinel });
  try {
    assert.equal(process.env[present], sentinel);
    assert.equal(Object.hasOwn(process.env, absent), false);

    const inner = isolateEnv({ [absent]: "temporary" });
    assert.equal(process.env[present], undefined);
    assert.equal(process.env[absent], "temporary");
    inner();

    // Set var came back; unset var is unset again rather than an empty string.
    assert.equal(process.env[present], sentinel);
    assert.equal(Object.hasOwn(process.env, absent), false);
  } finally {
    outer();
  }
});

test("withIsolatedEnv restores the environment even when the body throws", () => {
  const key = AMBIENT_STATE_ENV[0];
  const restore = isolateEnv({ [key]: "outer" });
  try {
    assert.throws(() => {
      withIsolatedEnv({ [key]: "inner" }, () => {
        assert.equal(process.env[key], "inner");
        throw new Error("boom");
      });
    }, /boom/);
    assert.equal(process.env[key], "outer");
  } finally {
    restore();
  }
});

test("job queries see their fixtures despite a hostile ambient session id", () => {
  // Reproduces the original failure: CODEX_TOOLKIT_SESSION_ID is set inside any
  // cc-suite-enabled Claude Code session, and job queries drop every job that
  // does not carry it — silently emptying results for jobs created without one.
  const restore = isolateEnv({
    CODEX_TOOLKIT_SESSION_ID: "some-other-session",
  });
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "amb-1",
      kind: "audit",
      status: "completed",
      summary: "fixture",
    });

    // Ambient id still set: the fixture is filtered out.
    assert.equal(buildStatusSnapshot(workspace).latestFinished, null);

    // Isolated: the fixture is visible.
    withIsolatedEnv({}, () => {
      assert.equal(buildStatusSnapshot(workspace).latestFinished.id, "amb-1");
      assert.equal(resolveResultJob(workspace, null).job.id, "amb-1");
    });
  } finally {
    restore();
    cleanupDir(workspace);
  }
});
