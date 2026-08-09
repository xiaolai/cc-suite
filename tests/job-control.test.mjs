import fs from "node:fs";
import test, { before, after } from "node:test";
import assert from "node:assert/strict";

import { makeTempDir, cleanupDir, isolateEnv } from "./helpers.mjs";
import { listJobs, upsertJob } from "../scripts/lib/state.mjs";
import { processAlive, readProcessStartTime } from "../scripts/lib/process.mjs";
import {
  sortJobsNewestFirst,
  enrichJob,
  buildStatusSnapshot,
  resolveResultJob,
  resolveCancelableJob,
  readJobProgressPreview,
  cancelJob,
} from "../scripts/lib/job-control.mjs";

// buildStatusSnapshot and resolveResultJob filter jobs by the ambient session
// id, and these tests create jobs with none. Without isolation an inherited
// CODEX_TOOLKIT_SESSION_ID filters every fixture out and the queries look empty.
let restoreEnv;
before(() => {
  restoreEnv = isolateEnv();
});
after(() => {
  restoreEnv?.();
});

test("sortJobsNewestFirst sorts by updatedAt descending", () => {
  const jobs = [
    { id: "a", updatedAt: "2026-01-01T00:00:00Z" },
    { id: "c", updatedAt: "2026-01-03T00:00:00Z" },
    { id: "b", updatedAt: "2026-01-02T00:00:00Z" },
  ];
  const sorted = sortJobsNewestFirst(jobs);
  assert.deepEqual(
    sorted.map((j) => j.id),
    ["c", "b", "a"]
  );
});

test("enrichJob adds kindLabel, phase, elapsed", () => {
  const job = {
    id: "job-1",
    kind: "audit",
    status: "running",
    createdAt: new Date(Date.now() - 60000).toISOString(),
  };
  const enriched = enrichJob(job);
  assert.equal(enriched.kindLabel, "audit");
  assert.equal(enriched.phase, "running");
  assert.ok(enriched.elapsed);
});

test("enrichJob computes duration for completed jobs", () => {
  const start = new Date(Date.now() - 120000).toISOString();
  const end = new Date().toISOString();
  const job = {
    id: "job-2",
    kind: "implement",
    status: "completed",
    startedAt: start,
    completedAt: end,
  };
  const enriched = enrichJob(job);
  assert.equal(enriched.kindLabel, "implement");
  assert.ok(enriched.duration);
  assert.match(enriched.duration, /\d+[hms]/);
});

test("buildStatusSnapshot returns structured report", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "snap-1",
      kind: "audit",
      status: "completed",
      summary: "test audit",
    });
    upsertJob(workspace, {
      id: "snap-2",
      kind: "implement",
      status: "running",
      summary: "implementing feature",
    });
    const snapshot = buildStatusSnapshot(workspace);
    assert.equal(snapshot.running.length, 1);
    assert.equal(snapshot.running[0].id, "snap-2");
    assert.ok(snapshot.latestFinished);
    assert.equal(snapshot.latestFinished.id, "snap-1");
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveResultJob finds latest completed job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "res-1",
      kind: "audit",
      status: "completed",
    });
    const { job } = resolveResultJob(workspace, null);
    assert.equal(job.id, "res-1");
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveResultJob throws for running job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "res-run",
      kind: "audit",
      status: "running",
    });
    assert.throws(() => resolveResultJob(workspace, "res-run"), /still running/);
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveCancelableJob finds single active job", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "can-1",
      kind: "audit",
      status: "running",
    });
    const { job } = resolveCancelableJob(workspace, null);
    assert.equal(job.id, "can-1");
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveCancelableJob throws when multiple active without reference", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, { id: "can-a", kind: "audit", status: "running" });
    upsertJob(workspace, {
      id: "can-b",
      kind: "implement",
      status: "running",
    });
    assert.throws(() => resolveCancelableJob(workspace, null), /Multiple/);
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveCancelableJob supports prefix matching", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "cancel-unique-123",
      kind: "audit",
      status: "running",
    });
    const { job } = resolveCancelableJob(workspace, "cancel-unique");
    assert.equal(job.id, "cancel-unique-123");
  } finally {
    cleanupDir(workspace);
  }
});

test("readJobProgressPreview returns empty for missing log", () => {
  const lines = readJobProgressPreview("/nonexistent/path.log");
  assert.deepEqual(lines, []);
});

test("readJobProgressPreview reads last N lines from log", () => {
  const workspace = makeTempDir();
  const logFile = `${workspace}/test.log`;
  try {
    const entries = Array.from(
      { length: 10 },
      (_, i) => `[2026-01-01T00:0${i}:00Z] Step ${i}`
    );
    fs.writeFileSync(logFile, entries.join("\n") + "\n", "utf8");
    const preview = readJobProgressPreview(logFile, 3);
    assert.equal(preview.length, 3);
    assert.equal(preview[0], "Step 7");
    assert.equal(preview[2], "Step 9");
  } finally {
    cleanupDir(workspace);
  }
});

test("resolveResultJob treats stalled jobs as finished results", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, { id: "stalled-1", kind: "audit", status: "stalled" });
    const { job } = resolveResultJob(workspace);
    assert.equal(job.id, "stalled-1");
  } finally {
    cleanupDir(workspace);
  }
});

test("enrichJob labels non-enumerated kinds by their kind, not 'job'", () => {
  const enriched = enrichJob({ id: "x", kind: "agy", status: "completed" });
  assert.equal(enriched.kindLabel, "agy");
});

test("cancelJob refuses to signal a PID it cannot prove is the job's own", async () => {
  const workspace = makeTempDir();
  const { spawn } = await import("node:child_process");
  const bystander = spawn(process.execPath, ["-e", "setTimeout(()=>{},60000)"], {
    detached: true,
    stdio: "ignore",
  });
  bystander.unref();
  await new Promise((r) => setTimeout(r, 300));
  try {
    upsertJob(workspace, {
      id: "cancel-recycled",
      kind: "audit",
      status: "running",
      pid: bystander.pid,
      pidStartedAt: "Mon Jan  1 00:00:00 2020", // stale identity
    });
    const result = cancelJob(workspace, "cancel-recycled");
    assert.equal(result.outcome, "already-exited");

    let alive = true;
    try {
      process.kill(bystander.pid, 0);
    } catch (error) {
      alive = error?.code === "EPERM";
    }
    assert.equal(alive, true, "cancelJob killed an unrelated process");
    assert.equal(listJobs(workspace)[0].status, "cancelled");
  } finally {
    try {
      process.kill(bystander.pid, "SIGKILL");
    } catch {}
    cleanupDir(workspace);
  }
});

test("cancelJob terminates a job process it owns and confirms the exit", async () => {
  const workspace = makeTempDir();
  const { spawn } = await import("node:child_process");
  const child = spawn(process.execPath, ["-e", "setTimeout(()=>{},60000)"], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  await new Promise((r) => setTimeout(r, 300));
  try {
    upsertJob(workspace, {
      id: "cancel-live",
      kind: "audit",
      status: "running",
      pid: child.pid,
      pidStartedAt: readProcessStartTime(child.pid),
    });
    const result = cancelJob(workspace, "cancel-live");
    assert.equal(result.outcome, "terminated");
    assert.equal(result.terminated, true);
    assert.equal(processAlive(child.pid), false);
    assert.equal(listJobs(workspace)[0].status, "cancelled");
  } finally {
    try {
      process.kill(child.pid, "SIGKILL");
    } catch {}
    cleanupDir(workspace);
  }
});

test("cancelJob records why a job with no PID could not be signalled", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, { id: "cancel-queued", kind: "audit", status: "queued" });
    const result = cancelJob(workspace, "cancel-queued");
    assert.equal(result.outcome, "no-pid");
    assert.equal(result.terminated, false);
    const job = listJobs(workspace)[0];
    assert.equal(job.status, "cancelled");
    assert.match(job.errorMessage, /no recorded PID/);
  } finally {
    cleanupDir(workspace);
  }
});

test("cancelJob does not claim success when process identity cannot be checked", async () => {
  const workspace = makeTempDir();
  const { spawn } = await import("node:child_process");
  const child = spawn(process.execPath, ["-e", "setTimeout(()=>{},60000)"], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  await new Promise((r) => setTimeout(r, 300));
  const realPath = process.env.PATH;
  try {
    upsertJob(workspace, {
      id: "cancel-nops",
      kind: "audit",
      status: "running",
      pid: child.pid,
      pidStartedAt: readProcessStartTime(child.pid),
    });
    // No `ps` on PATH: identity cannot be proven. The process is demonstrably
    // alive, so reporting it as already-exited would be a lie that also lets
    // SessionEnd delete the record of a running process.
    process.env.PATH = "/nonexistent";
    const result = cancelJob(workspace, "cancel-nops");
    process.env.PATH = realPath;

    assert.equal(result.outcome, "unverifiable");
    assert.equal(result.terminated, false);
    assert.equal(processAlive(child.pid), true, "an unverifiable job must not be signalled");
    const job = listJobs(workspace)[0];
    assert.equal(job.terminationConfirmed, false);
    assert.match(job.errorMessage, /process-identity/);
  } finally {
    process.env.PATH = realPath;
    try {
      process.kill(child.pid, "SIGKILL");
    } catch {}
    cleanupDir(workspace);
  }
});
