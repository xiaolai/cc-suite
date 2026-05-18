import test from "node:test";
import assert from "node:assert/strict";

import {
  renderStatusReport,
  renderJobResult,
  renderCancelReport,
  renderSetupReport,
  renderAuditFindings,
} from "../scripts/lib/render.mjs";

test("renderStatusReport shows empty state", () => {
  const report = {
    config: { stopReviewGate: false },
    running: [],
    latestFinished: null,
    recent: [],
    needsReview: false,
  };
  const output = renderStatusReport(report);
  assert.ok(output.includes("Codex Toolkit Status"));
  assert.ok(output.includes("No jobs recorded yet"));
  assert.ok(output.includes("Review gate: disabled"));
});

test("renderStatusReport shows running jobs", () => {
  const report = {
    config: { stopReviewGate: true },
    running: [
      {
        id: "job-1",
        kind: "audit",
        kindLabel: "audit",
        status: "running",
        phase: "running",
        elapsed: "2m 30s",
        threadId: "t-123",
        summary: "auditing code",
      },
    ],
    latestFinished: null,
    recent: [],
    needsReview: true,
  };
  const output = renderStatusReport(report);
  assert.ok(output.includes("Active Jobs"));
  assert.ok(output.includes("job-1"));
  assert.ok(output.includes("audit"));
  assert.ok(output.includes("review gate is enabled"));
});

test("renderStatusReport shows latest finished and recent", () => {
  const report = {
    config: { stopReviewGate: false },
    running: [],
    latestFinished: {
      id: "job-fin",
      kind: "audit",
      kindLabel: "audit",
      status: "completed",
      duration: "1m 5s",
      threadId: "t-fin",
      summary: "completed audit",
    },
    recent: [
      {
        id: "job-old",
        kind: "implement",
        kindLabel: "implement",
        status: "completed",
        duration: "5m 0s",
        summary: "old implementation",
      },
    ],
    needsReview: false,
  };
  const output = renderStatusReport(report);
  assert.ok(output.includes("Latest Finished"));
  assert.ok(output.includes("job-fin"));
  assert.ok(output.includes("Recent Jobs"));
  assert.ok(output.includes("job-old"));
});

test("renderJobResult renders raw output with thread ID", () => {
  const job = { id: "j-1", kind: "audit", kindLabel: "audit", status: "completed" };
  const stored = { rawOutput: "Found 3 issues.", threadId: "t-abc" };
  const output = renderJobResult(job, stored);
  assert.ok(output.includes("Found 3 issues."));
  assert.ok(output.includes("Thread ID: t-abc"));
  assert.ok(output.includes("/continue t-abc"));
});

test("renderJobResult handles missing raw output", () => {
  const job = {
    id: "j-2",
    kind: "audit",
    kindLabel: "audit",
    status: "completed",
    summary: "test",
  };
  const stored = {};
  const output = renderJobResult(job, stored);
  assert.ok(output.includes("No captured result"));
});

test("renderCancelReport formats cancel info", () => {
  const job = { id: "c-1", kind: "audit", summary: "running audit" };
  const output = renderCancelReport(job);
  assert.ok(output.includes("Cancelled c-1"));
  assert.ok(output.includes("running audit"));
});

test("renderSetupReport shows ready state", () => {
  const report = {
    ready: true,
    node: "v22.0.0",
    codex: "1.2.0",
    auth: "authenticated",
    reviewGateEnabled: false,
    nextSteps: [],
  };
  const output = renderSetupReport(report);
  assert.ok(output.includes("Status: ready"));
  assert.ok(output.includes("v22.0.0"));
});

test("renderSetupReport shows needs attention with next steps", () => {
  const report = {
    ready: false,
    node: "v22.0.0",
    codex: "not found",
    auth: "not authenticated",
    reviewGateEnabled: false,
    nextSteps: [
      "Install Codex: npm install -g @openai/codex",
      "Authenticate: codex login",
    ],
  };
  const output = renderSetupReport(report);
  assert.ok(output.includes("Status: needs attention"));
  assert.ok(output.includes("not found"));
  assert.ok(output.includes("npm install -g"));
});

test("renderAuditFindings renders sorted findings table", () => {
  const findings = [
    {
      severity: "low",
      title: "Minor issue",
      body: "A minor thing",
      file: "src/a.ts",
      line_start: 10,
      line_end: 10,
      recommendation: "Fix it",
    },
    {
      severity: "critical",
      title: "Major bug",
      body: "This is bad",
      file: "src/b.ts",
      line_start: 5,
      line_end: 15,
      recommendation: "Rewrite",
    },
  ];
  const output = renderAuditFindings(findings);
  // Critical should come before low
  const critIdx = output.indexOf("critical");
  const lowIdx = output.indexOf("low");
  assert.ok(critIdx < lowIdx, "Critical should be listed before low");
  assert.ok(output.includes("src/b.ts:5-15"));
  assert.ok(output.includes("src/a.ts:10"));
});

test("renderAuditFindings handles empty findings", () => {
  assert.equal(renderAuditFindings([]), "No findings.\n");
  assert.equal(renderAuditFindings(null), "No findings.\n");
});
