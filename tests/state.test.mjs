import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { before, after } from "node:test";
import assert from "node:assert/strict";

import {
  makeTempDir,
  cleanupDir,
  isolateEnv,
  withIsolatedEnv,
} from "./helpers.mjs";
import {
  resolveStateDir,
  resolveStateFile,
  resolveJobFile,
  resolveJobLogFile,
  loadState,
  saveState,
  upsertJob,
  listJobs,
  generateJobId,
  setConfig,
  getConfig,
  writeJobFile,
  readJobFile,
} from "../scripts/lib/state.mjs";

// State resolution reads the environment, so the whole file runs hermetically.
// Tests that need a specific value declare it via withIsolatedEnv.
let restoreEnv;
before(() => {
  restoreEnv = isolateEnv();
});
after(() => {
  restoreEnv?.();
});

test("resolveStateDir uses a temp-backed per-workspace directory", () => {
  const workspace = makeTempDir();
  try {
    const stateDir = resolveStateDir(workspace);
    assert.equal(stateDir.startsWith(os.tmpdir()), true);
    assert.match(path.basename(stateDir), /.+-[a-f0-9]{16}$/);
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveStateDir uses CLAUDE_PLUGIN_DATA when set", () => {
  const workspace = makeTempDir();
  const pluginDataDir = makeTempDir();
  try {
    withIsolatedEnv({ CLAUDE_PLUGIN_DATA: pluginDataDir }, () => {
      const stateDir = resolveStateDir(workspace);
      assert.equal(
        stateDir.startsWith(path.join(pluginDataDir, "state")),
        true
      );
      assert.match(path.basename(stateDir), /.+-[a-f0-9]{16}$/);
    });
  } finally {
    cleanupDir(workspace);
    cleanupDir(pluginDataDir);
  }
});

test("loadState returns default state when no file exists", () => {
  const workspace = makeTempDir();
  try {
    const state = loadState(workspace);
    assert.equal(state.version, 1);
    assert.deepEqual(state.config, { stopReviewGate: false });
    assert.deepEqual(state.jobs, []);
  } finally {
    cleanupDir(workspace);
  }
});

test("saveState and loadState round-trip", () => {
  const workspace = makeTempDir();
  try {
    const state = {
      version: 1,
      config: { stopReviewGate: true },
      jobs: [
        {
          id: "job-1",
          kind: "audit",
          status: "completed",
          updatedAt: new Date().toISOString(),
        },
      ],
    };
    saveState(workspace, state);
    const loaded = loadState(workspace);
    assert.equal(loaded.config.stopReviewGate, true);
    assert.equal(loaded.jobs.length, 1);
    assert.equal(loaded.jobs[0].id, "job-1");
  } finally {
    cleanupDir(workspace);
  }
});

test("saveState prunes jobs exceeding MAX_JOBS (50)", () => {
  const workspace = makeTempDir();
  try {
    const jobs = Array.from({ length: 51 }, (_, i) => {
      const jobId = `job-${i}`;
      const updatedAt = new Date(
        Date.UTC(2026, 0, 1, 0, i, 0)
      ).toISOString();
      const logFile = resolveJobLogFile(workspace, jobId);
      const jobFile = resolveJobFile(workspace, jobId);
      fs.writeFileSync(logFile, `log ${jobId}\n`, "utf8");
      fs.writeFileSync(
        jobFile,
        JSON.stringify({ id: jobId, status: "completed" }),
        "utf8"
      );
      return { id: jobId, status: "completed", logFile, updatedAt };
    });

    saveState(workspace, { version: 1, config: {}, jobs });
    const loaded = loadState(workspace);
    assert.equal(loaded.jobs.length, 50);
    // Oldest job (job-0) should be pruned
    assert.equal(
      loaded.jobs.find((j) => j.id === "job-0"),
      undefined
    );
    // Newest job (job-50) should be retained
    assert.notEqual(
      loaded.jobs.find((j) => j.id === "job-50"),
      undefined
    );
  } finally {
    cleanupDir(workspace);
  }
});

test("upsertJob inserts a new job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "test-job-1",
      kind: "audit",
      status: "running",
    });
    const jobs = listJobs(workspace);
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].id, "test-job-1");
    assert.equal(jobs[0].status, "running");
    assert.ok(jobs[0].createdAt);
    assert.ok(jobs[0].updatedAt);
  } finally {
    cleanupDir(workspace);
  }
});

test("upsertJob updates an existing job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "test-job-2",
      kind: "audit",
      status: "running",
    });
    upsertJob(workspace, {
      id: "test-job-2",
      status: "completed",
      threadId: "thread-abc",
    });
    const jobs = listJobs(workspace);
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].status, "completed");
    assert.equal(jobs[0].threadId, "thread-abc");
    assert.equal(jobs[0].kind, "audit"); // preserved from insert
  } finally {
    cleanupDir(workspace);
  }
});

test("generateJobId produces unique IDs with prefix", () => {
  const id1 = generateJobId("audit");
  const id2 = generateJobId("audit");
  assert.match(id1, /^audit-/);
  assert.notEqual(id1, id2);
});

test("setConfig and getConfig persist configuration", () => {
  const workspace = makeTempDir();
  try {
    setConfig(workspace, "stopReviewGate", true);
    const config = getConfig(workspace);
    assert.equal(config.stopReviewGate, true);

    setConfig(workspace, "stopReviewGate", false);
    assert.equal(getConfig(workspace).stopReviewGate, false);
  } finally {
    cleanupDir(workspace);
  }
});

test("writeJobFile and readJobFile round-trip", () => {
  const workspace = makeTempDir();
  try {
    const payload = { rawOutput: "test output", threadId: "t-123" };
    const jobFile = writeJobFile(workspace, "job-rw", payload);
    const loaded = readJobFile(jobFile);
    assert.deepEqual(loaded, payload);
  } finally {
    cleanupDir(workspace);
  }
});
