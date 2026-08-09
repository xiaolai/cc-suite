import { spawn } from "node:child_process";
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
  claimJob,
  createJobLogFile,
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

test("loadState quarantines a structurally invalid state file", () => {
  const workspace = makeTempDir();
  try {
    const stateFile = resolveStateFile(workspace);
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    // jobs must be an array — the file itself is unusable.
    fs.writeFileSync(stateFile, JSON.stringify({ jobs: { a: 1 } }), "utf8");
    const state = loadState(workspace);
    assert.deepEqual(state.jobs, []);
    const quarantined = fs
      .readdirSync(path.dirname(stateFile))
      .filter((name) => name.startsWith("state.json.corrupt-"));
    assert.equal(quarantined.length, 1);
  } finally {
    cleanupDir(workspace);
  }
});

test("one malformed job entry drops that entry, not the whole state", () => {
  const workspace = makeTempDir();
  try {
    const stateFile = resolveStateFile(workspace);
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(
      stateFile,
      JSON.stringify({
        version: 1,
        config: {},
        jobs: [
          null,
          { id: "../../../evil", status: "completed" },
          { id: "keep-me", kind: "audit", status: "running", pid: 4242 },
        ],
      }),
      "utf8"
    );
    const state = loadState(workspace);
    // The valid, still-active job must survive — discarding it would leave its
    // process running with nothing tracking it.
    assert.deepEqual(state.jobs.map((j) => j.id), ["keep-me"]);
    const quarantined = fs
      .readdirSync(path.dirname(stateFile))
      .filter((name) => name.startsWith("state.json.corrupt-"));
    assert.equal(quarantined.length, 0, "a bad entry must not quarantine the file");
  } finally {
    cleanupDir(workspace);
  }
});

test("upsertJob rejects an unusable job id at the write path", () => {
  const workspace = makeTempDir();
  try {
    assert.throws(() => upsertJob(workspace, { id: "../../evil", status: "running" }));
    assert.throws(() => upsertJob(workspace, { status: "running" }));
    assert.deepEqual(listJobs(workspace), []);
  } finally {
    cleanupDir(workspace);
  }
});

test("claimJob refuses to recreate a job that no longer exists", () => {
  const workspace = makeTempDir();
  try {
    const claimed = claimJob(workspace, "vanished-1", { status: "running", pid: 7 });
    assert.equal(claimed, false);
    assert.deepEqual(listJobs(workspace), []);
  } finally {
    cleanupDir(workspace);
  }
});

test("state directory and job logs are not group- or world-readable", () => {
  const workspace = makeTempDir();
  try {
    const logFile = createJobLogFile(workspace, "perm-1");
    fs.appendFileSync(logFile, "sensitive reviewed source\n", "utf8");
    assert.equal(fs.statSync(logFile).mode & 0o077, 0, "job log is readable by others");
    assert.equal(
      fs.statSync(resolveStateDir(workspace)).mode & 0o077,
      0,
      "state dir is accessible to others"
    );
  } finally {
    cleanupDir(workspace);
  }
});

test("an existing world-readable state directory is tightened on next use", () => {
  const workspace = makeTempDir();
  try {
    const stateDir = resolveStateDir(workspace);
    fs.mkdirSync(path.join(stateDir, "jobs"), { recursive: true });
    fs.chmodSync(stateDir, 0o777);
    upsertJob(workspace, { id: "harden-1", kind: "audit", status: "queued" });
    assert.equal(fs.statSync(stateDir).mode & 0o077, 0);
  } finally {
    cleanupDir(workspace);
  }
});

test("loadState propagates operational read errors instead of quarantining", () => {
  const workspace = makeTempDir();
  try {
    const stateFile = resolveStateFile(workspace);
    // A directory at the state file path yields EISDIR — an I/O problem, not
    // corruption. The file must not be quarantined-renamed away.
    fs.mkdirSync(stateFile, { recursive: true });
    assert.throws(() => loadState(workspace));
    assert.equal(fs.existsSync(stateFile), true);
  } finally {
    cleanupDir(workspace);
  }
});

test("job id grammar is enforced before touching the filesystem", () => {
  const workspace = makeTempDir();
  try {
    assert.throws(() => resolveJobFile(workspace, "../evil"));
    assert.throws(() => resolveJobLogFile(workspace, "a/b"));
    assert.throws(() => writeJobFile(workspace, "..", {}));
    assert.throws(() => generateJobId("../audit"));
    assert.throws(() => generateJobId(""));
  } finally {
    cleanupDir(workspace);
  }
});

test("saveState refuses to delete log files outside the jobs directory", () => {
  const workspace = makeTempDir();
  const outside = makeTempDir();
  try {
    const victim = path.join(outside, "victim.log");
    fs.writeFileSync(victim, "precious\n", "utf8");
    saveState(workspace, {
      version: 1,
      config: {},
      jobs: [
        {
          id: "job-evil",
          status: "completed",
          logFile: victim,
          updatedAt: new Date().toISOString(),
        },
      ],
    });
    // Dropping the job prunes it — its outside-the-jobs-dir logFile must survive.
    saveState(workspace, { version: 1, config: {}, jobs: [] });
    assert.equal(fs.existsSync(victim), true);
  } finally {
    cleanupDir(workspace);
    cleanupDir(outside);
  }
});

test("saveState cleans artifacts of jobs pruned straight from the input", () => {
  const workspace = makeTempDir();
  try {
    const jobs = Array.from({ length: 51 }, (_, i) => {
      const jobId = `fresh-${i}`;
      const logFile = resolveJobLogFile(workspace, jobId);
      const jobFile = resolveJobFile(workspace, jobId);
      fs.writeFileSync(logFile, `log ${jobId}\n`, "utf8");
      fs.writeFileSync(jobFile, JSON.stringify({ id: jobId }), "utf8");
      const updatedAt = new Date(Date.UTC(2026, 0, 1, 0, i, 0)).toISOString();
      return { id: jobId, status: "completed", logFile, updatedAt };
    });
    // No previously persisted state: every pruned job comes from the input.
    saveState(workspace, { version: 1, config: {}, jobs });
    assert.equal(fs.existsSync(resolveJobLogFile(workspace, "fresh-0")), false);
    assert.equal(fs.existsSync(resolveJobFile(workspace, "fresh-0")), false);
    assert.equal(fs.existsSync(resolveJobLogFile(workspace, "fresh-50")), true);
    // resolveJobLogFile must stay side-effect free, or this assertion would
    // create the very file it is checking for.
    assert.equal(fs.existsSync(resolveJobLogFile(workspace, "never-existed")), false);
  } finally {
    cleanupDir(workspace);
  }
});

test("concurrent upsertJob calls from separate processes do not lose jobs", async () => {
  const workspace = makeTempDir();
  try {
    const script = `
      import { upsertJob } from ${JSON.stringify(
        new URL("../scripts/lib/state.mjs", import.meta.url).href
      )};
      // node -e consumes the "--" separator: the passthrough args are the
      // final two argv entries, not argv.slice(2).
      const [workspace, prefix] = process.argv.slice(-2);
      for (let i = 0; i < 20; i++) {
        upsertJob(workspace, { id: prefix + "-" + i, kind: "audit", status: "completed" });
      }
    `;
    const run = (prefix) =>
      new Promise((resolve) => {
        const child = spawn(
          process.execPath,
          ["--input-type=module", "-e", script, "--", workspace, prefix],
          { stdio: ["ignore", "ignore", "pipe"], env: process.env }
        );
        let stderr = "";
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (code) => resolve({ code, stderr }));
      });
    const results = await Promise.all([run("alpha"), run("beta")]);
    for (const result of results) {
      assert.equal(result.code, 0, result.stderr);
    }
    const ids = new Set(listJobs(workspace).map((j) => j.id));
    for (const prefix of ["alpha", "beta"]) {
      for (let i = 0; i < 20; i++) {
        assert.ok(ids.has(`${prefix}-${i}`), `missing ${prefix}-${i}`);
      }
    }
  } finally {
    cleanupDir(workspace);
  }
});

test("claimJob refuses to resurrect a cancelled job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, { id: "wk-1", kind: "audit", status: "queued" });
    upsertJob(workspace, { id: "wk-1", status: "cancelled" });
    const claimed = claimJob(workspace, "wk-1", { status: "running", pid: 1234 });
    assert.equal(claimed, false);
    assert.equal(listJobs(workspace)[0].status, "cancelled");
    assert.equal(listJobs(workspace)[0].pid, undefined);
  } finally {
    cleanupDir(workspace);
  }
});

test("claimJob applies the patch for a queued job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, { id: "wk-2", kind: "audit", status: "queued" });
    const claimed = claimJob(workspace, "wk-2", { status: "running", pid: 4321 });
    assert.equal(claimed, true);
    const job = listJobs(workspace)[0];
    assert.equal(job.status, "running");
    assert.equal(job.pid, 4321);
    assert.equal(job.kind, "audit"); // preserved
  } finally {
    cleanupDir(workspace);
  }
});

test("an unreclaimable lock times out instead of spinning forever", () => {
  const workspace = makeTempDir();
  try {
    const stateDir = resolveStateDir(workspace);
    fs.mkdirSync(path.join(stateDir, "jobs"), { recursive: true });
    // A FILE where the lock directory belongs: rmdir can never succeed, so a
    // reclaim-and-retry loop with no deadline check would spin at 100% CPU.
    const lockPath = path.join(stateDir, "state.lock");
    fs.writeFileSync(lockPath, "not a directory\n", "utf8");
    const old = Date.now() - 60_000;
    fs.utimesSync(lockPath, new Date(old), new Date(old));

    const started = Date.now();
    assert.throws(
      () => upsertJob(workspace, { id: "spin-1", kind: "audit", status: "queued" }),
      /timed out waiting for state lock/
    );
    const elapsed = Date.now() - started;
    assert.ok(elapsed < 30_000, `lock wait took ${elapsed}ms — expected a bounded timeout`);
  } finally {
    cleanupDir(workspace);
  }
});
