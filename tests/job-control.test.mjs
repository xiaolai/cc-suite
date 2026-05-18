import fs from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";

import { makeTempDir, cleanupDir } from "./helpers.mjs";
import { upsertJob } from "../scripts/lib/state.mjs";
import {
  sortJobsNewestFirst,
  enrichJob,
  buildStatusSnapshot,
  resolveResultJob,
  resolveCancelableJob,
  readJobProgressPreview,
} from "../scripts/lib/job-control.mjs";

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
