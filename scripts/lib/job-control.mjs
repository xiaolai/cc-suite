import fs from "node:fs";

import { getConfig, listJobs, readJobFile, resolveJobFile } from "./state.mjs";
import { resolveWorkspaceRoot } from "./workspace.mjs";

export const SESSION_ID_ENV = "CODEX_TOOLKIT_SESSION_ID";
export const DEFAULT_MAX_STATUS_JOBS = 8;
export const DEFAULT_MAX_PROGRESS_LINES = 4;

export function sortJobsNewestFirst(jobs) {
  return [...jobs].sort((a, b) =>
    String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? ""))
  );
}

function getCurrentSessionId(options = {}) {
  return options.env?.[SESSION_ID_ENV] ?? process.env[SESSION_ID_ENV] ?? null;
}

function filterJobsForCurrentSession(jobs, options = {}) {
  const sessionId = getCurrentSessionId(options);
  if (!sessionId) return jobs;
  return jobs.filter((j) => j.sessionId === sessionId);
}

function getJobTypeLabel(job) {
  if (typeof job.kindLabel === "string" && job.kindLabel) return job.kindLabel;
  if (job.kind === "audit") return "audit";
  if (job.kind === "audit-fix") return "audit-fix";
  if (job.kind === "implement") return "implement";
  if (job.kind === "bug-analyze") return "bug-analyze";
  if (job.kind === "review-plan") return "review-plan";
  if (job.kind === "verify") return "verify";
  return "job";
}

function stripLogPrefix(line) {
  return line.replace(/^\[[^\]]+\]\s*/, "").trim();
}

const PROGRESS_PREVIEW_TAIL_BYTES = 64 * 1024;

export function readJobProgressPreview(logFile, maxLines = DEFAULT_MAX_PROGRESS_LINES) {
  if (!logFile || !fs.existsSync(logFile)) return [];
  // Read only a bounded tail window so large logs never make status slow.
  let tail;
  let start = 0;
  try {
    const fd = fs.openSync(logFile, "r");
    try {
      const size = fs.fstatSync(fd).size;
      start = Math.max(0, size - PROGRESS_PREVIEW_TAIL_BYTES);
      const buffer = Buffer.alloc(size - start);
      fs.readSync(fd, buffer, 0, buffer.length, start);
      tail = buffer.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
    if (start > 0) {
      // Drop the first line: it may be a fragment of a truncated line.
      const firstNewline = tail.indexOf("\n");
      tail = firstNewline === -1 ? "" : tail.slice(firstNewline + 1);
    }
  } catch {
    return [];
  }
  const lines = tail
    .split(/\r?\n/)
    .map((l) => l.trimEnd())
    .filter(Boolean)
    .filter((l) => l.startsWith("["))
    .map(stripLogPrefix)
    .filter(Boolean);
  return lines.slice(-maxLines);
}

function formatElapsedDuration(startValue, endValue = null) {
  const start = Date.parse(startValue ?? "");
  if (!Number.isFinite(start)) return null;
  const end = endValue ? Date.parse(endValue) : Date.now();
  if (!Number.isFinite(end) || end < start) return null;

  const totalSeconds = Math.max(0, Math.round((end - start) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

export function enrichJob(job, options = {}) {
  const maxProgressLines =
    options.maxProgressLines ?? DEFAULT_MAX_PROGRESS_LINES;
  const isActive = job.status === "queued" || job.status === "running";

  return {
    ...job,
    kindLabel: getJobTypeLabel(job),
    progressPreview: isActive || job.status === "failed"
      ? readJobProgressPreview(job.logFile, maxProgressLines)
      : [],
    elapsed: formatElapsedDuration(
      job.startedAt ?? job.createdAt,
      job.completedAt ?? null
    ),
    duration: !isActive
      ? formatElapsedDuration(
          job.startedAt ?? job.createdAt,
          job.completedAt ?? job.updatedAt
        )
      : null,
    phase: job.phase ?? (isActive ? "running" : job.status),
  };
}

export function readStoredJob(workspaceRoot, jobId) {
  const jobFile = resolveJobFile(workspaceRoot, jobId);
  if (!fs.existsSync(jobFile)) return null;
  return readJobFile(jobFile);
}

function matchJobReference(jobs, reference, predicate = () => true) {
  const filtered = jobs.filter(predicate);
  if (!reference) return filtered[0] ?? null;

  const exact = filtered.find((j) => j.id === reference);
  if (exact) return exact;

  const prefixMatches = filtered.filter((j) => j.id.startsWith(reference));
  if (prefixMatches.length === 1) return prefixMatches[0];
  if (prefixMatches.length > 1) {
    throw new Error(
      `Job reference "${reference}" is ambiguous. Use a longer job id.`
    );
  }
  throw new Error(
    `No job found for "${reference}". Run /codex-toolkit:status to list known jobs.`
  );
}

export function buildStatusSnapshot(cwd, options = {}) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const config = getConfig(workspaceRoot);
  const jobs = sortJobsNewestFirst(
    filterJobsForCurrentSession(listJobs(workspaceRoot), options)
  );
  const maxJobs = options.maxJobs ?? DEFAULT_MAX_STATUS_JOBS;
  const maxProgressLines =
    options.maxProgressLines ?? DEFAULT_MAX_PROGRESS_LINES;

  const running = jobs
    .filter((j) => j.status === "queued" || j.status === "running")
    .map((j) => enrichJob(j, { maxProgressLines }));

  const latestFinishedRaw =
    jobs.find((j) => j.status !== "queued" && j.status !== "running") ?? null;
  const latestFinished = latestFinishedRaw
    ? enrichJob(latestFinishedRaw, { maxProgressLines })
    : null;

  // Filter to finished jobs before applying the cap, so active jobs and the
  // latest-finished entry cannot consume the recent-jobs window.
  const finishedRecent = jobs.filter(
    (j) =>
      j.status !== "queued" &&
      j.status !== "running" &&
      j.id !== latestFinished?.id
  );
  const recent = (options.all
    ? finishedRecent
    : finishedRecent.slice(0, maxJobs)
  ).map((j) => enrichJob(j, { maxProgressLines }));

  return {
    workspaceRoot,
    config,
    running,
    latestFinished,
    recent,
    needsReview: Boolean(config.stopReviewGate),
  };
}

export function resolveResultJob(cwd, reference) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const jobs = sortJobsNewestFirst(
    reference
      ? listJobs(workspaceRoot)
      : filterJobsForCurrentSession(listJobs(workspaceRoot))
  );

  // Check if there are any finished jobs matching the reference
  const finishedJobs = jobs.filter(
    (j) =>
      j.status === "completed" ||
      j.status === "failed" ||
      j.status === "cancelled"
  );

  if (reference) {
    // Resolve exact/prefix identity across ALL jobs first, then branch on the
    // selected job's status — otherwise a finished prefix match (abc-old) can
    // shadow an active exact match (abc).
    let selected = jobs.find((j) => j.id === reference) ?? null;
    if (!selected) {
      const prefixMatches = jobs.filter((j) => j.id.startsWith(reference));
      if (prefixMatches.length > 1) {
        throw new Error(
          `Job reference "${reference}" is ambiguous. Use a longer job id.`
        );
      }
      selected = prefixMatches[0] ?? null;
    }
    if (!selected) {
      throw new Error(
        `No job found for "${reference}". Run /codex-toolkit:status to list known jobs.`
      );
    }
    if (selected.status === "queued" || selected.status === "running") {
      throw new Error(
        `Job ${selected.id} is still ${selected.status}. Check /codex-toolkit:status.`
      );
    }
    return { workspaceRoot, job: selected };
  }

  // No reference — return latest finished
  if (finishedJobs.length > 0) {
    return { workspaceRoot, job: finishedJobs[0] };
  }

  // Check if anything is running
  const activeJob = jobs.find(
    (j) => j.status === "queued" || j.status === "running"
  );
  if (activeJob) {
    throw new Error(
      `Job ${activeJob.id} is still ${activeJob.status}. Check /codex-toolkit:status.`
    );
  }

  throw new Error("No finished Codex jobs found for this workspace.");
}

export function resolveCancelableJob(cwd, reference) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const jobs = sortJobsNewestFirst(listJobs(workspaceRoot));
  const activeJobs = jobs.filter(
    (j) => j.status === "queued" || j.status === "running"
  );

  if (reference) {
    const selected = matchJobReference(activeJobs, reference);
    if (!selected)
      throw new Error(`No active job found for "${reference}".`);
    return { workspaceRoot, job: selected };
  }

  if (activeJobs.length === 1) {
    return { workspaceRoot, job: activeJobs[0] };
  }
  if (activeJobs.length > 1) {
    throw new Error(
      "Multiple jobs are active. Pass a job id to /codex-toolkit:cancel."
    );
  }
  throw new Error("No active Codex jobs to cancel.");
}
