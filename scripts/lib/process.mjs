import { spawnSync } from "node:child_process";
import process from "node:process";

export function runCommand(command, args = [], options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: "utf8",
    input: options.input,
    stdio: options.stdio ?? "pipe",
    timeout: options.timeout,
  });

  return {
    command,
    args,
    // Preserve null for signal-terminated children — coercing to 0 would
    // report a killed process as success.
    status: result.status ?? null,
    signal: result.signal ?? null,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    error: result.error ?? null,
  };
}

export function runCommandChecked(command, args = [], options = {}) {
  const result = runCommand(command, args, options);
  if (result.error) throw result.error;
  if (result.status !== 0 || result.signal) {
    throw new Error(formatCommandFailure(result));
  }
  return result;
}

export function binaryAvailable(command, versionArgs = ["--version"]) {
  const result = runCommand(command, versionArgs);
  if (result.error?.code === "ENOENT") {
    return { available: false, detail: "not found" };
  }
  if (result.error) {
    return { available: false, detail: result.error.message };
  }
  if (result.status !== 0 || result.signal) {
    const detail =
      result.stderr.trim() ||
      result.stdout.trim() ||
      (result.signal ? `signal ${result.signal}` : `exit ${result.status}`);
    return { available: false, detail };
  }
  return {
    available: true,
    detail: result.stdout.trim() || result.stderr.trim() || "ok",
  };
}

export function terminateProcessTree(pid, options = {}) {
  // Strictly positive integers only: kill(0)/kill(-0) signals the caller's own
  // process group, and a negative pid flips the group/process semantics.
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    return { attempted: false, delivered: false, method: null };
  }

  const killImpl = options.killImpl ?? process.kill.bind(process);
  const signal = options.signal ?? "SIGTERM";

  // Try process group first (Unix)
  try {
    killImpl(-pid, signal);
    return { attempted: true, delivered: true, method: "process-group" };
  } catch {
    // Group kill failed — including ESRCH, which only proves no process
    // group with that id exists; the process itself may still be alive
    // without being a group leader. Always fall back to the positive PID.
    try {
      killImpl(pid, signal);
      return { attempted: true, delivered: true, method: "process" };
    } catch (innerError) {
      if (innerError?.code === "ESRCH") {
        return { attempted: true, delivered: false, method: "process" };
      }
      throw innerError;
    }
  }
}

// Runners spawn their backend `detached` so a deadline can terminate the whole
// process tree. detached calls setsid(2), which also moves the child out of the
// runner's process group — so terminal Ctrl-C, SIGHUP on hangup, shell job
// control, and `kill -- -PGID` no longer reach it, and killing the runner would
// leave the backend running with nothing tracking it.
//
// Forward those signals to the child's group, then re-raise on the runner so its
// own exit status still reflects the signal. Returns a release function; call it
// once the child is finished, or the installed listeners suppress Node's default
// termination behaviour for the rest of the process's life.
export function installChildSignalForwarding(
  child,
  signals = ["SIGINT", "SIGTERM", "SIGHUP"]
) {
  const handlers = new Map();
  const release = () => {
    for (const [signal, handler] of handlers) {
      process.removeListener(signal, handler);
    }
    handlers.clear();
  };

  for (const signal of signals) {
    const handler = () => {
      try {
        terminateProcessTree(child.pid, { signal: "SIGTERM" });
      } catch {
        // Nothing to forward to, or not permitted — still re-raise below.
      }
      release();
      try {
        process.kill(process.pid, signal);
      } catch {
        process.exit(1);
      }
    };
    handlers.set(signal, handler);
    process.on(signal, handler);
  }
  return release;
}

export function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Block until every pid in `pids` has exited, or the budget expires. Returns
// the set of pids still alive. The budget is shared across all pids so a caller
// terminating N jobs does not pay N × the grace period.
export function waitForExit(pids, budgetMs, pollMs = 50) {
  const deadline = Date.now() + budgetMs;
  let alive = [...pids].filter(processAlive);
  while (alive.length > 0 && Date.now() < deadline) {
    sleepSync(pollMs);
    alive = alive.filter(processAlive);
  }
  return new Set(alive);
}

// A process's start time, used as an identity token so a recycled PID is never
// mistaken for the original job process. `ps -o lstart=` exists on macOS and
// Linux; returns null when the process is gone or ps is unavailable.
export function readProcessStartTime(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  // Pin timezone and locale: the process that records the token and the one
  // that later verifies it can run under different environments — a background
  // worker outlives the shell that started it, and a GUI-launched session has
  // no LANG — and `ps -o lstart=` renders local time in the current locale. A
  // drifting format would read as a recycled PID.
  const result = runCommand("ps", ["-o", "lstart=", "-p", String(pid)], {
    env: { ...process.env, TZ: "UTC", LC_ALL: "C" },
  });
  if (result.status !== 0 || result.signal || result.error) return null;
  return result.stdout.trim() || null;
}

// True when `pid` names a process that has not yet exited. EPERM means the
// process exists but belongs to another user, which still counts as alive.
//
// A zombie does NOT count as alive: it has already terminated and only its exit
// status remains in the table. kill(pid, 0) still succeeds on one, so callers
// waiting for an exit would otherwise wait forever whenever the target is an
// unreaped child of the caller.
export function processAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error?.code !== "EPERM") return false;
    return true; // another user's process: exists, and we cannot inspect it
  }
  return !isZombie(pid);
}

function isZombie(pid) {
  const result = runCommand("ps", ["-o", "stat=", "-p", String(pid)], {
    env: { ...process.env, LC_ALL: "C" },
  });
  // A `ps` failure leaves the answer optimistic (not a zombie), which keeps a
  // live process looking alive — the safe direction for every caller here.
  if (result.status !== 0 || result.signal || result.error) return false;
  return result.stdout.trim().startsWith("Z");
}

export function formatCommandFailure(result) {
  const parts = [`${result.command} ${result.args.join(" ")}`.trim()];
  if (result.signal) {
    parts.push(`signal=${result.signal}`);
  } else {
    parts.push(`exit=${result.status}`);
  }
  const stderr = (result.stderr || "").trim();
  const stdout = (result.stdout || "").trim();
  if (stderr) parts.push(stderr);
  else if (stdout) parts.push(stdout);
  return parts.join(": ");
}
