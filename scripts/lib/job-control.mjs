import fs from "node:fs";

import {
  getConfig,
  isActiveJob,
  isTerminalJob,
  listJobs,
  readJobFile,
  resolveJobFile,
  updateState,
} from "./state.mjs";
import {
  processAlive,
  readProcessStartTime,
  terminateProcessTree,
  waitForExit,
} from "./process.mjs";
import { resolveWorkspaceRoot } from "./workspace.mjs";

// Grace periods for confirming a signalled job actually exited.
const TERM_CONFIRM_MS = 1500;
const KILL_CONFIRM_MS = 500;

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
  // Any recorded kind (audit, agy, grok, continue, …) is its own label;
  // collapsing unknown kinds to "job" misreported valid runners in status.
  if (typeof job.kind === "string" && job.kind) return job.kind;
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
  const isActive = isActiveJob(job);

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
    `No job found for "${reference}". Run /cc-suite:status to list known jobs.`
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
    .filter(isActiveJob)
    .map((j) => enrichJob(j, { maxProgressLines }));

  const latestFinishedRaw = jobs.find(isTerminalJob) ?? null;
  const latestFinished = latestFinishedRaw
    ? enrichJob(latestFinishedRaw, { maxProgressLines })
    : null;

  // Filter to finished jobs before applying the cap, so active jobs and the
  // latest-finished entry cannot consume the recent-jobs window.
  const finishedRecent = jobs.filter(
    (j) => isTerminalJob(j) && j.id !== latestFinished?.id
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

  // Terminal jobs (completed, failed, cancelled, stalled) are all resolvable
  // results — a stalled job still has a log worth reading.
  const finishedJobs = jobs.filter(isTerminalJob);

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
        `No job found for "${reference}". Run /cc-suite:status to list known jobs.`
      );
    }
    if (isActiveJob(selected)) {
      throw new Error(
        `Job ${selected.id} is still ${selected.status}. Check /cc-suite:status.`
      );
    }
    return { workspaceRoot, job: selected };
  }

  // No reference — return latest finished
  if (finishedJobs.length > 0) {
    return { workspaceRoot, job: finishedJobs[0] };
  }

  // Check if anything is running
  const activeJob = jobs.find(isActiveJob);
  if (activeJob) {
    throw new Error(
      `Job ${activeJob.id} is still ${activeJob.status}. Check /cc-suite:status.`
    );
  }

  throw new Error("No finished Codex jobs found for this workspace.");
}

// Decide whether `job.pid` still identifies this job's own process. A bare PID
// is not proof: PIDs are recycled, and signalling a recycled one would kill an
// unrelated process. Jobs record `pidStartedAt` (the OS-reported process start
// time) when they claim `running`; identity holds only when that still matches.
export function verifyJobProcess(job) {
  const pid = typeof job?.pid === "number" ? job.pid : Number.NaN;
  if (!Number.isSafeInteger(pid) || pid <= 0) return { pid: null, state: "no-pid" };
  if (!processAlive(pid)) return { pid, state: "gone" };
  if (!job.pidStartedAt) {
    // Written by an older cc-suite that did not record process identity.
    // Refuse to signal rather than risk an unrelated process.
    return { pid, state: "unverifiable" };
  }
  const current = readProcessStartTime(pid);
  if (current === null) {
    // The liveness check above already proved this PID is alive, so a null here
    // means `ps` failed (missing, busybox without -o lstart, restricted PATH),
    // not that the process died. Reporting "gone" would let a caller delete the
    // record and claim the job was terminated while it keeps running.
    return { pid, state: "unverifiable" };
  }
  if (current !== job.pidStartedAt) return { pid, state: "recycled" };
  return { pid, state: "ours" };
}

// Terminate a job's process and confirm it actually exited. Never signals a PID
// whose identity cannot be proven. Returns an outcome describing exactly what
// happened, so callers report the truth instead of assuming success.
export function terminateJobProcess(job) {
  const identity = verifyJobProcess(job);
  switch (identity.state) {
    case "no-pid":
      return { outcome: "no-pid", terminated: false, detail: "no recorded PID, so the job process could not be terminated" };
    case "gone":
      return { outcome: "already-exited", terminated: true, detail: "the job process had already exited" };
    case "recycled":
      return { outcome: "already-exited", terminated: true, detail: "the recorded PID was recycled by an unrelated process; the job process is gone and was not signalled" };
    case "unverifiable":
      return { outcome: "unverifiable", terminated: false, detail: "the job predates process-identity tracking, so it was not signalled and may still be running" };
    default:
      break;
  }

  try {
    const sent = terminateProcessTree(identity.pid, { signal: "SIGTERM" });
    if (sent.attempted && !sent.delivered) {
      return { outcome: "already-exited", terminated: true, detail: "the job process had already exited" };
    }
  } catch (error) {
    return { outcome: "signal-failed", terminated: false, detail: `terminating the job process failed (${error?.message || error}), so it may still be running` };
  }

  let alive = waitForExit([identity.pid], TERM_CONFIRM_MS);
  if (alive.size > 0) {
    // Re-prove identity before escalating: the PID could have been recycled
    // between the last poll and now, and SIGKILL is unsurvivable.
    if (verifyJobProcess(job).state !== "ours") {
      return { outcome: "already-exited", terminated: true, detail: "the job process exited and its PID was reused" };
    }
    try {
      terminateProcessTree(identity.pid, { signal: "SIGKILL" });
    } catch {}
    alive = waitForExit([identity.pid], KILL_CONFIRM_MS);
  }
  return alive.size === 0
    ? { outcome: "terminated", terminated: true, detail: "the job process exited" }
    : { outcome: "not-confirmed", terminated: false, detail: "SIGTERM and SIGKILL were delivered but the process had not exited yet" };
}

// Resolve, terminate, and persist a cancellation in one step.
//
// The job is always moved out of the active list — a cancel request should not
// leave it looking runnable — but `terminationConfirmed` records whether the
// process is actually known to be gone. Callers must report that honestly
// rather than claiming success, and SessionEnd uses it to decide whether the
// record may be dropped: deleting a job whose process still runs would hide it.
export function cancelJob(cwd, reference) {
  const { workspaceRoot, job } = resolveCancelableJob(cwd, reference);
  const result = terminateJobProcess(job);
  const timestamp = new Date().toISOString();

  let raced = null;
  updateState(workspaceRoot, (state) => {
    const idx = state.jobs.findIndex((j) => j.id === job.id);
    if (idx === -1) {
      raced = "the job record disappeared while the cancel was in flight";
      return;
    }
    const current = state.jobs[idx];
    // Re-read guard: terminating and confirming took real time, and the job may
    // have finished on its own. Overwriting a genuine terminal status with
    // `cancelled` would misreport what happened.
    if (!isActiveJob(current)) {
      raced = `the job finished on its own (${current.status}) before the cancel was recorded`;
      return;
    }
    state.jobs[idx] = {
      ...current,
      status: "cancelled",
      terminationConfirmed: result.terminated,
      ...(result.terminated ? {} : { errorMessage: `Cancel requested; ${result.detail}.` }),
      completedAt: timestamp,
      updatedAt: timestamp,
    };
  });

  if (raced) {
    return { workspaceRoot, job, outcome: "already-finished", terminated: true, detail: raced };
  }
  return { workspaceRoot, job, ...result };
}

export function resolveCancelableJob(cwd, reference) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const jobs = sortJobsNewestFirst(listJobs(workspaceRoot));
  const activeJobs = jobs.filter(isActiveJob);

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
      "Multiple jobs are active. Pass a job id to /cc-suite:cancel."
    );
  }
  throw new Error("No active Codex jobs to cancel.");
}
