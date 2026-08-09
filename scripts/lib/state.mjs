import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { resolveWorkspaceRoot } from "./workspace.mjs";

const STATE_VERSION = 1;
const PLUGIN_DATA_ENV = "CLAUDE_PLUGIN_DATA";
const FALLBACK_STATE_ROOT_DIR = path.join(os.tmpdir(), "codex-toolkit");
const STATE_FILE_NAME = "state.json";
const JOBS_DIR_NAME = "jobs";
const LOCK_DIR_NAME = "state.lock";
const LOCK_STALE_MS = 10_000;
const LOCK_TIMEOUT_MS = 15_000;
const LOCK_POLL_MS = 25;
const MAX_JOBS = 50;

// Job ids become file names under the jobs directory; anything outside this
// grammar (path separators, leading dots) could escape it.
const JOB_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const JOB_PREFIX_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*$/;

function nowIso() {
  return new Date().toISOString();
}

function assertValidJobId(jobId) {
  if (typeof jobId !== "string" || !JOB_ID_PATTERN.test(jobId)) {
    throw new Error(`cc-suite: invalid job id ${JSON.stringify(jobId)}`);
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Locks held by this process, so nested state calls (updateState → saveState)
// do not deadlock on their own lock.
const heldLocks = new Set();

function withStateLock(cwd, fn) {
  const stateDir = resolveStateDir(cwd);
  const lockDir = path.join(stateDir, LOCK_DIR_NAME);
  if (heldLocks.has(lockDir)) return fn();
  ensureStateDir(cwd);

  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  let acquired = false;
  while (!acquired) {
    try {
      fs.mkdirSync(lockDir);
      acquired = true;
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }

    // Someone holds the lock, or something else occupies the path. Try to
    // reclaim it if it is stale, then ALWAYS fall through to the deadline check
    // and a sleep. No branch may loop without making progress — a reclaim that
    // cannot succeed (a file at the path, a non-empty directory, EPERM on a
    // read-only or networked filesystem) would otherwise spin at 100% CPU and
    // never time out.
    let holder = null;
    try {
      holder = fs.lstatSync(lockDir);
    } catch (statError) {
      if (statError?.code !== "ENOENT") throw statError;
    }
    if (holder && Date.now() - holder.mtimeMs > LOCK_STALE_MS) {
      try {
        // Remove only the exact directory observed: between the stat and here
        // the holder may have released and a third process re-locked, and
        // stealing that one would put two writers inside the lock.
        const current = fs.lstatSync(lockDir);
        if (current.ino === holder.ino && current.isDirectory()) {
          fs.rmdirSync(lockDir);
        }
      } catch {
        // Could not reclaim; the deadline below is what bounds this wait.
      }
    }

    if (Date.now() > deadline) {
      throw new Error(
        `cc-suite: timed out waiting for state lock at ${lockDir}`
      );
    }
    sleepSync(LOCK_POLL_MS);
  }

  // Identify the directory we created so release cannot remove a lock that a
  // stale-steal handed to someone else while we were suspended.
  let ownIno = null;
  try {
    ownIno = fs.lstatSync(lockDir).ino;
  } catch {}

  heldLocks.add(lockDir);
  try {
    return fn();
  } finally {
    heldLocks.delete(lockDir);
    try {
      const current = fs.lstatSync(lockDir);
      if (ownIno === null || current.ino === ownIno) fs.rmdirSync(lockDir);
    } catch {}
  }
}

function defaultState() {
  return {
    version: STATE_VERSION,
    config: {
      stopReviewGate: false,
    },
    jobs: [],
  };
}

export function resolveStateDir(cwd) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  let canonicalRoot = workspaceRoot;
  try {
    canonicalRoot = fs.realpathSync.native(workspaceRoot);
  } catch {
    canonicalRoot = workspaceRoot;
  }

  const slugSource = path.basename(workspaceRoot) || "workspace";
  const slug = slugSource
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "workspace";
  const hash = createHash("sha256")
    .update(canonicalRoot)
    .digest("hex")
    .slice(0, 16);
  const pluginDataDir = process.env[PLUGIN_DATA_ENV];
  const stateRoot = pluginDataDir
    ? path.join(pluginDataDir, "state")
    : FALLBACK_STATE_ROOT_DIR;
  return path.join(stateRoot, `${slug}-${hash}`);
}

export function resolveStateFile(cwd) {
  return path.join(resolveStateDir(cwd), STATE_FILE_NAME);
}

export function resolveJobsDir(cwd) {
  return path.join(resolveStateDir(cwd), JOBS_DIR_NAME);
}

// 0700 on directories, 0600 on files: the fallback state root lives under the
// shared system temp dir at a fully predictable path, and job logs and result
// files carry reviewed source and model output.
function hardenDir(dir) {
  // mkdir's `mode` applies only to directories it creates, so an install
  // upgraded from a version that used the default umask keeps its old
  // permissions until something tightens them explicitly.
  let stat;
  try {
    stat = fs.lstatSync(dir);
  } catch {
    return;
  }
  if (stat.isSymbolicLink()) {
    throw new Error(
      `cc-suite: refusing to use a symlinked state directory: ${dir}`
    );
  }
  if ((stat.mode & 0o077) !== 0) {
    try {
      fs.chmodSync(dir, 0o700);
    } catch {}
  }
}

export function ensureStateDir(cwd) {
  const stateDir = resolveStateDir(cwd);
  const jobsDir = resolveJobsDir(cwd);
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });
  hardenDir(stateDir);
  hardenDir(jobsDir);
}

function quarantineStateFile(stateFile, cause) {
  const quarantineFile = `${stateFile}.corrupt-${Date.now()}`;
  const detail = cause?.message ?? String(cause);
  try {
    fs.renameSync(stateFile, quarantineFile);
    process.stderr.write(
      `cc-suite: state file was unreadable (${detail}); quarantined to ${quarantineFile}\n`
    );
  } catch {
    process.stderr.write(
      `cc-suite: state file is unreadable (${detail}) and could not be quarantined; using default state\n`
    );
  }
}

function validateStateShape(parsed) {
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("state root is not an object");
  }
  if (parsed.config !== undefined) {
    if (
      typeof parsed.config !== "object" ||
      parsed.config === null ||
      Array.isArray(parsed.config)
    ) {
      throw new Error("state.config is not an object");
    }
  }
  if (parsed.jobs !== undefined) {
    if (!Array.isArray(parsed.jobs)) {
      throw new Error("state.jobs is not an array");
    }
  }
}

// Structural problems (a non-object root, a non-array `jobs`) mean the file is
// unusable and get quarantined. A single malformed ENTRY does not: dropping the
// bad rows keeps every valid job — including active ones whose processes would
// otherwise become untracked orphans — instead of discarding the whole file.
function usableJobs(jobs) {
  const kept = [];
  for (const job of jobs) {
    if (typeof job !== "object" || job === null || Array.isArray(job)) continue;
    if (typeof job.id !== "string" || !JOB_ID_PATTERN.test(job.id)) {
      process.stderr.write(
        `cc-suite: dropping state entry with unusable job id ${JSON.stringify(job.id)}\n`
      );
      continue;
    }
    kept.push(job);
  }
  return kept;
}

export function loadState(cwd) {
  const stateFile = resolveStateFile(cwd);
  let raw;
  try {
    raw = fs.readFileSync(stateFile, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return defaultState();
    // Operational read failures (permissions, I/O) are not corruption:
    // quarantining here would rename a valid state file away.
    throw error;
  }
  try {
    const parsed = JSON.parse(raw);
    validateStateShape(parsed);
    return {
      ...defaultState(),
      ...parsed,
      config: { ...defaultState().config, ...(parsed.config ?? {}) },
      jobs: usableJobs(Array.isArray(parsed.jobs) ? parsed.jobs : []),
    };
  } catch (error) {
    quarantineStateFile(stateFile, error);
    return defaultState();
  }
}

// Shared job-status predicates. "stalled" is a terminal status written by the
// runners — any filter that enumerates terminal statuses by hand risks
// omitting it, so every consumer must go through these.
export function isActiveJob(job) {
  return job.status === "queued" || job.status === "running";
}

export function isTerminalJob(job) {
  return !isActiveJob(job);
}

function pruneJobs(jobs) {
  const sorted = [...jobs].sort((a, b) =>
    String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? ""))
  );
  // Active jobs are never pruned; the cap applies to terminal jobs only.
  const activeCount = sorted.filter(isActiveJob).length;
  const terminalBudget = Math.max(0, MAX_JOBS - activeCount);
  let terminalKept = 0;
  return sorted.filter((job) => {
    if (isActiveJob(job)) return true;
    if (terminalKept < terminalBudget) {
      terminalKept += 1;
      return true;
    }
    return false;
  });
}

function writeFileAtomic(filePath, content) {
  const tmpFile = `${filePath}.tmp-${process.pid}-${Math.random()
    .toString(36)
    .slice(2, 8)}`;
  try {
    const fd = fs.openSync(tmpFile, "w", 0o600);
    try {
      fs.writeFileSync(fd, content, "utf8");
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmpFile, filePath);
  } catch (error) {
    try {
      fs.unlinkSync(tmpFile);
    } catch {}
    throw error;
  }
}

export function saveState(cwd, state) {
  return withStateLock(cwd, () => {
    const previousJobs = loadState(cwd).jobs;
    ensureStateDir(cwd);
    const nextJobs = pruneJobs(state.jobs ?? []);
    const nextState = {
      version: STATE_VERSION,
      config: { ...defaultState().config, ...(state.config ?? {}) },
      jobs: nextJobs,
    };

    // Commit the new state atomically before deleting pruned artifacts, so an
    // interrupted save never leaves the old state referencing deleted files.
    writeFileAtomic(
      resolveStateFile(cwd),
      `${JSON.stringify(nextState, null, 2)}\n`
    );

    // Clean artifacts for every job that did not survive the prune — both
    // previously persisted jobs and jobs pruned straight from the input list,
    // which would otherwise leak their .json/.log files.
    const retainedIds = new Set(nextJobs.map((j) => j.id));
    // Resolve both sides: a relative CLAUDE_PLUGIN_DATA would otherwise make
    // every deletion fail the containment check.
    const jobsDir = path.resolve(resolveJobsDir(cwd));
    const removed = new Map();
    for (const job of [...previousJobs, ...(state.jobs ?? [])]) {
      if (!job || typeof job.id !== "string") continue;
      if (retainedIds.has(job.id) || removed.has(job.id)) continue;
      removed.set(job.id, job);
    }
    for (const job of removed.values()) {
      if (!JOB_ID_PATTERN.test(job.id)) continue;
      removeJobFile(resolveJobFile(cwd, job.id));
      removeManagedFile(job.logFile, jobsDir);
    }
    return nextState;
  });
}

export function updateState(cwd, mutate) {
  return withStateLock(cwd, () => {
    const state = loadState(cwd);
    mutate(state);
    return saveState(cwd, state);
  });
}

export function generateJobId(prefix = "job") {
  if (typeof prefix !== "string" || !JOB_PREFIX_PATTERN.test(prefix)) {
    throw new Error(`cc-suite: invalid job id prefix ${JSON.stringify(prefix)}`);
  }
  const random = Math.random().toString(36).slice(2, 8);
  return `${prefix}-${Date.now().toString(36)}-${random}`;
}

export function upsertJob(cwd, jobPatch) {
  assertValidJobId(jobPatch?.id);
  return updateState(cwd, (state) => {
    const timestamp = nowIso();
    const idx = state.jobs.findIndex((j) => j.id === jobPatch.id);
    if (idx === -1) {
      state.jobs.unshift({
        createdAt: timestamp,
        updatedAt: timestamp,
        ...jobPatch,
      });
      return;
    }
    state.jobs[idx] = {
      ...state.jobs[idx],
      ...jobPatch,
      updatedAt: timestamp,
    };
  });
}

export function listJobs(cwd) {
  return loadState(cwd).jobs;
}

// Atomically apply `patch` to a job unless its current status is in `unless`.
// Returns true when the patch was applied. Background workers use this to
// claim their queued job: a job cancelled by SessionEnd between queue and
// worker startup must stay cancelled, not be resurrected to running.
export function claimJob(cwd, jobId, patch, { unless = ["cancelled"] } = {}) {
  assertValidJobId(jobId);
  let claimed = false;
  updateState(cwd, (state) => {
    const timestamp = nowIso();
    const idx = state.jobs.findIndex((j) => j.id === jobId);
    if (idx === -1) {
      // The record is gone (pruned, or the state file was replaced). Recreating
      // it here would produce a stub with no kind, summary, or logFile, which
      // /status renders as an unidentifiable "job" — refuse instead.
      return;
    }
    if (unless.includes(state.jobs[idx].status)) return;
    state.jobs[idx] = { ...state.jobs[idx], ...patch, updatedAt: timestamp };
    claimed = true;
  });
  return claimed;
}

export function setConfig(cwd, key, value) {
  return updateState(cwd, (state) => {
    state.config = { ...state.config, [key]: value };
  });
}

export function getConfig(cwd) {
  return loadState(cwd).config;
}

export function writeJobFile(cwd, jobId, payload) {
  ensureStateDir(cwd);
  const jobFile = resolveJobFile(cwd, jobId);
  writeFileAtomic(jobFile, `${JSON.stringify(payload, null, 2)}\n`);
  return jobFile;
}

export function readJobFile(jobFile) {
  return JSON.parse(fs.readFileSync(jobFile, "utf8"));
}

// Deletes a persisted artifact path only when it resolves inside the jobs
// directory — a corrupt or hostile state record must not unlink other files.
function removeManagedFile(filePath, jobsDir) {
  if (!filePath || typeof filePath !== "string") return;
  const resolved = path.resolve(filePath);
  if (resolved === jobsDir || !resolved.startsWith(jobsDir + path.sep)) {
    process.stderr.write(
      `cc-suite: refusing to delete ${filePath} outside the jobs directory\n`
    );
    return;
  }
  if (fs.existsSync(resolved)) {
    fs.unlinkSync(resolved);
  }
}

function removeJobFile(jobFile) {
  if (fs.existsSync(jobFile)) {
    fs.unlinkSync(jobFile);
  }
}

// Pure: returns the path without touching the filesystem beyond ensuring the
// jobs directory exists. Callers that are about to write use createJobLogFile.
export function resolveJobLogFile(cwd, jobId) {
  assertValidJobId(jobId);
  ensureStateDir(cwd);
  return path.join(resolveJobsDir(cwd), `${jobId}.log`);
}

// Resolve the log path AND create it with restrictive permissions. The runners
// reach the file through appendFileSync, which would otherwise create it at
// 0666 & ~umask, and job logs carry reviewed source and model output.
export function createJobLogFile(cwd, jobId) {
  const logFile = resolveJobLogFile(cwd, jobId);
  try {
    fs.closeSync(fs.openSync(logFile, "a", 0o600));
    const stat = fs.statSync(logFile);
    if ((stat.mode & 0o077) !== 0) fs.chmodSync(logFile, 0o600);
  } catch {}
  return logFile;
}

export function resolveJobFile(cwd, jobId) {
  assertValidJobId(jobId);
  ensureStateDir(cwd);
  return path.join(resolveJobsDir(cwd), `${jobId}.json`);
}
