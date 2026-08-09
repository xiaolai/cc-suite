#!/usr/bin/env node
// grok-runner.mjs — Run Grok Build (xAI) tasks in foreground or background with
// job tracking. Mirrors agy-runner.mjs / codex-runner.mjs so /cc-suite:status,
// /result, /cancel, and /continue work identically across all backends.
//
// Usage:
//   node grok-runner.mjs --kind <kind> --model <model> --effort <effort> \
//     --sandbox <sandbox> [--resume <sessionId>] [--timeout-ms <ms>] \
//     [--background] [--session-id <id>] [--summary <text>] -- <prompt>
//
// ─── How Grok differs from the codex/agy runners ─────────────────────────────
//
// Grok exposes an Agent Client Protocol (ACP) interface: `grok agent stdio`
// speaks JSON-RPC over stdin/stdout, and any app can act as the *client* that
// drives Grok as the *agent*. This runner is that ACP client. Unlike the
// codex/agy runners (which shell out and scrape text/JSONL from a CLI), we drive
// a structured protocol:
//
//   initialize → session/new (or session/load on resume) → session/prompt
//
// and accumulate `agent_message_chunk` text from the streamed `session/update`
// notifications as the answer. The session id ACP returns is stored as the
// job's threadId, so /cc-suite:continue resumes the same Grok session.
//
// Sandbox mapping (cc-suite vocabulary → ACP permission behavior):
//   read-only          → no --always-approve; the client REJECTS permission
//                        requests and denies fs writes. Grok can still run tools
//                        that need no permission (reads). Caveat: a global
//                        permission_mode="always-approve" in ~/.grok/config.toml
//                        can pre-approve tools before the client is consulted;
//                        read-only is best-effort, not a hard sandbox.
//   workspace-write    → --always-approve; the client serves fs read/write.
//   danger-full-access → --always-approve (Grok has no stricter tier via ACP).

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import {
  claimJob,
  generateJobId,
  upsertJob,
  writeJobFile,
  createJobLogFile,
} from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";
import {
  installChildSignalForwarding,
  readProcessStartTime,
  terminateProcessTree,
  waitForExit,
} from "./lib/process.mjs";
import { withDelegationBoundary } from "./lib/delegation-boundary.mjs";

const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes — matches the other runners
const HEARTBEAT_MS = 30 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;
// ACP defines protocolVersion as a number, not a string; strict agents reject
// a string "1" at initialize.
const ACP_PROTOCOL_VERSION = 1;
// After session/prompt resolves, agent_message_chunk notifications can still be
// in flight; drain until the answer is quiet before killing the child.
const ANSWER_QUIET_MS = 500;
const ANSWER_DRAIN_MAX_MS = 5000;

const VALID_SANDBOXES = new Set(["read-only", "workspace-write", "danger-full-access"]);

// Job id this process has registered but not yet finalized (or handed off to a
// detached worker). main()'s rejection handler marks it failed so a crash can
// never leave a foreground job recorded as running forever.
let activeJobId = null;

// A value-taking flag must be followed by a real value. "" is the background
// argv convention for "unset" and keeps its historical skip-the-flag behavior.
function flagValue(value, flag) {
  if (value.startsWith("--")) {
    process.stderr.write(`Error: ${flag} requires a value, got '${value}'\n`);
    process.exit(1);
  }
  return value;
}

const KNOWN_FLAGS = new Set([
  "--kind", "--model", "--effort", "--sandbox", "--resume", "--timeout-ms",
  "--background", "--session-id", "--summary",
]);

function parseArgs(argv) {
  const args = {
    kind: "grok",
    model: null,
    effort: null,
    sandbox: "read-only",
    resume: null,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    background: false,
    sessionId: null,
    summary: null,
    prompt: null,
  };

  // Every token before `--` must be a known flag (or a flag value): unknown
  // options, stray positionals, missing flag values, and malformed values all
  // fail loudly pre-spawn instead of being silently dropped.
  let i = 2;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--") {
      args.prompt = argv.slice(i + 1).join(" ");
      break;
    }
    if (arg === "--background") {
      args.background = true;
      i += 1;
      continue;
    }
    if (!KNOWN_FLAGS.has(arg)) {
      process.stderr.write(
        arg.startsWith("--")
          ? `Error: unknown option '${arg}'\n`
          : `Error: unexpected argument '${arg}' — the prompt must follow '--'\n`
      );
      process.exit(1);
    }
    if (i + 1 >= argv.length) {
      process.stderr.write(`Error: ${arg} requires a value\n`);
      process.exit(1);
    }
    const raw = argv[i + 1];
    i += 2;
    if (raw === "") continue; // background "" placeholder — flag stays unset
    const value = flagValue(raw, arg);
    switch (arg) {
      case "--kind": args.kind = value; break;
      case "--model": args.model = value; break;
      case "--effort": args.effort = value; break;
      case "--sandbox": args.sandbox = value; break;
      case "--resume": args.resume = value; break;
      case "--session-id": args.sessionId = value; break;
      case "--summary": args.summary = value; break;
      case "--timeout-ms": {
        const n = Number(value);
        // Node timers cap at 2^31-1 ms; larger values wrap to ~1ms and fire
        // an immediate false timeout.
        if (!Number.isInteger(n) || n <= 0 || n > 2147483647) {
          process.stderr.write(`Error: --timeout-ms requires a positive integer of milliseconds (max 2147483647), got '${value}'\n`);
          process.exit(1);
        }
        args.timeoutMs = n;
        break;
      }
    }
  }

  return args;
}

function appendLog(logFile, message) {
  fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${message}\n`, "utf8");
}

// Build the `grok agent` argv. Parent-level flags (--model, --effort,
// --always-approve) precede the `stdio` subcommand.
function buildGrokArgs(args, alwaysApprove) {
  const grokArgs = ["agent"];
  if (args.model) grokArgs.push("--model", args.model);
  if (args.effort) grokArgs.push("--reasoning-effort", args.effort);
  if (alwaysApprove) grokArgs.push("--always-approve");
  grokArgs.push("stdio");
  return grokArgs;
}

// Drive `grok agent stdio` as an ACP client. Resolves with
// { status, rawOutput, sessionId, errorMessage }.
function executeGrok(cwd, args, logFile) {
  return new Promise((resolve) => {
    const alwaysApprove = args.sandbox !== "read-only";
    const grokArgs = buildGrokArgs(args, alwaysApprove);

    appendLog(logFile, `Exec: grok ${grokArgs.join(" ")} (ACP client driving)`);
    appendLog(logFile, `Model: ${args.model || "(default)"}, Effort: ${args.effort || "(default)"}, Sandbox: ${args.sandbox}${args.resume ? ` (resuming ${args.resume})` : ""}`);
    appendLog(logFile, `Deadline: ${Math.round(args.timeoutMs / 1000)}s`);

    // detached: the child leads its own process group so the deadline can
    // terminate the whole tree (tool subprocesses and MCP servers grok spawned),
    // not just the agent. installChildSignalForwarding below keeps a runner that
    // is itself killed from orphaning that group.
    const child = spawn("grok", grokArgs, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"], // stdin: JSON-RPC out, stdout: JSON-RPC in
      env: { ...process.env },
      detached: true,
    });
    const releaseSignals = installChildSignalForwarding(child);

    const startedAt = Date.now();
    const pending = new Map();
    let nextId = 1;
    let buf = "";
    let stderrTail = "";
    const answer = [];
    let toolCalls = 0;
    let settled = false;
    let timedOut = false;
    let killTimer = null;
    let acpSessionId = args.resume || null;
    let resumeFellBack = false; // resume requested, but session/load failed and a fresh session was started
    let phase = "spawn"; // spawn → initialize → authenticate → session → prompt → done
    let lastChunkAt = 0;
    let childClosed = false;

    const send = (obj) => { try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch { /* child gone */ } };
    const rpc = (method, params) => new Promise((res, rej) => {
      const id = nextId++;
      pending.set(id, { res, rej });
      send({ jsonrpc: "2.0", id, method, params });
    });
    const respond = (id, result) => send({ jsonrpc: "2.0", id, result });
    const respondErr = (id, message) => send({ jsonrpc: "2.0", id, error: { code: -32601, message } });

    // A dead agent pipe must reject in-flight RPCs instead of leaving them
    // pending forever (or crashing the runner via an unhandled stream error).
    function rejectAllPending(reason) {
      for (const [, p] of pending) p.rej(reason);
      pending.clear();
    }
    child.stdin.on("error", (err) => {
      rejectAllPending(new Error(`grok stdin closed: ${err.message}`));
    });

    function finish(result) {
      if (settled) return;
      settled = true;
      clearInterval(heartbeat);
      clearTimeout(deadline);
      if (killTimer) clearTimeout(killTimer);
      releaseSignals();
      try { terminateProcessTree(child.pid, { signal: "SIGTERM" }); } catch { /* already dead */ }
      // When a resume was requested, report explicitly whether it held; a
      // silent fresh-session fallback must not masquerade as continuation.
      resolve(args.resume ? { ...result, resumed: !resumeFellBack } : result);
    }


    // Terminate the child before settling on a failure path. Synchronous and
    // bounded on purpose: arming an escalation timer here would be cancelled by
    // finish(), which clears every timer, leaving a SIGTERM-resistant child
    // alive as a detached orphan.
    function killChildNow() {
      try { terminateProcessTree(child.pid, { signal: "SIGTERM" }); } catch {}
      if (waitForExit([child.pid], 1000).size > 0) {
        try { terminateProcessTree(child.pid, { signal: "SIGKILL" }); } catch {}
      }
    }

    // Timer and stream callbacks run outside the Promise chain: a synchronous
    // write failure (full disk, deleted log dir) would otherwise become an
    // uncaught exception that kills the runner and strands the job as running.
    function guarded(fn) {
      return (...callbackArgs) => {
        try {
          fn(...callbackArgs);
        } catch (error) {
          killChildNow();
          finish({
            status: "failed",
            errorMessage: `Runner callback failed: ${error?.message || error}`,
            sessionId: acpSessionId,
            rawOutput: answer.join("").trim(),
          });
        }
      };
    }

    const heartbeat = setInterval(
      guarded(() => {
        appendLog(logFile, `…still running (${Math.round((Date.now() - startedAt) / 1000)}s elapsed, ${toolCalls} tool call(s))`);
      }),
      HEARTBEAT_MS
    );

    const deadline = setTimeout(
      guarded(() => {
        timedOut = true;
        appendLog(logFile, `Deadline exceeded (${Math.round(args.timeoutMs / 1000)}s) — cancelling and terminating`);
        if (acpSessionId) send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: acpSessionId } });
        try { terminateProcessTree(child.pid, { signal: "SIGTERM" }); } catch {}
        killTimer = setTimeout(() => {
          if (!settled) {
            try { terminateProcessTree(child.pid, { signal: "SIGKILL" }); } catch {}
          }
        }, SIGKILL_GRACE_MS);
        killTimer.unref?.();
      }),
      args.timeoutMs
    );

    // ── ACP message dispatch (newline-delimited JSON-RPC) ────────────────────
    child.stdout.on("data", guarded((chunk) => {
      buf += chunk.toString("utf8");
      let nl;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl).replace(/\r$/, "");
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        let m;
        try { m = JSON.parse(line); } catch { continue; } // skip non-JSON banner lines
        if (process.env.GROK_ACP_DEBUG) appendLog(logFile, `<< ${m.method ? `notif/req ${m.method}${m.id !== undefined ? ` id=${m.id}` : ""}` : `resp id=${m.id}`}`);
        if (m.id !== undefined && (m.result !== undefined || m.error !== undefined) && pending.has(m.id)) {
          const p = pending.get(m.id); pending.delete(m.id);
          m.error ? p.rej(m.error) : p.res(m.result);
        } else if (m.method && m.id !== undefined) {
          handleAgentRequest(m);
        } else if (m.method) {
          handleNotification(m);
        }
      }
    }));

    function handleNotification(m) {
      if (m.method !== "session/update") return;
      const u = m.params?.update || {};
      if (u.sessionUpdate === "agent_message_chunk") {
        answer.push(u.content?.text ?? "");
        lastChunkAt = Date.now();
      }
      else if (u.sessionUpdate === "tool_call") { toolCalls++; appendLog(logFile, `tool_call: ${u.title || u.tool || u.toolCallId || "?"}`); }
    }

    // session/prompt resolving does not mean the streamed answer has fully
    // arrived — wait until no new chunk lands for ANSWER_QUIET_MS (bounded).
    async function drainAnswer() {
      const hardStop = Date.now() + ANSWER_DRAIN_MAX_MS;
      for (;;) {
        if (childClosed) return; // the stream is closed; no chunk can follow
        const reference = Math.max(lastChunkAt, startedAt);
        if (Date.now() - reference >= ANSWER_QUIET_MS) return;
        if (Date.now() >= hardStop) return;
        await new Promise((r) => setTimeout(r, 100));
      }
    }

    // Resolve an ACP-supplied path against the session cwd, canonicalize it,
    // and — except under danger-full-access — refuse anything that escapes the
    // workspace. Returns the resolved path, or null when containment fails.
    let workspaceRoot = cwd;
    try { workspaceRoot = fs.realpathSync.native(cwd); } catch { /* keep cwd */ }
    function resolveClientPath(rawPath, forWrite) {
      const resolved = path.resolve(cwd, String(rawPath ?? ""));
      if (args.sandbox === "danger-full-access") return resolved;
      let canonical = resolved;
      try {
        canonical = forWrite
          ? path.join(fs.realpathSync.native(path.dirname(resolved)), path.basename(resolved))
          : fs.realpathSync.native(resolved);
      } catch { /* target missing — containment-check the literal resolved path */ }
      const rel = path.relative(workspaceRoot, canonical);
      const inside = rel === "" || (!rel.startsWith(`..${path.sep}`) && rel !== ".." && !path.isAbsolute(rel));
      return inside ? resolved : null;
    }

    // Grok mostly uses its own tools, but ACP lets it call back to the client for
    // permissions and file I/O. Honor the sandbox here.
    function handleAgentRequest(m) {
      if (m.method === "session/request_permission") {
        const opts = m.params?.options || [];
        const want = alwaysApprove ? /allow|approve|yes/i : /reject|deny|no/i;
        const pick = opts.find((o) => want.test(o.optionId || o.kind || o.name || ""));
        if (!pick && !alwaysApprove) {
          // read-only: no reject-labelled option found — never select an
          // arbitrary fallback that could approve the operation.
          respond(m.id, { outcome: { outcome: "cancelled" } });
          return;
        }
        respond(m.id, { outcome: { outcome: "selected", optionId: (pick || opts[0])?.optionId } });
      } else if (m.method === "fs/read_text_file") {
        const target = resolveClientPath(m.params?.path, false);
        if (!target) { respondErr(m.id, `path outside workspace: ${m.params?.path}`); return; }
        try { respond(m.id, { content: fs.readFileSync(target, "utf8") }); }
        catch (e) { respondErr(m.id, String(e)); }
      } else if (m.method === "fs/write_text_file") {
        if (!alwaysApprove) { respondErr(m.id, "read-only: write denied"); return; }
        const target = resolveClientPath(m.params?.path, true);
        if (!target) { respondErr(m.id, `path outside workspace: ${m.params?.path}`); return; }
        try { fs.writeFileSync(target, m.params.content ?? ""); respond(m.id, {}); }
        catch (e) { respondErr(m.id, String(e)); }
      } else {
        respondErr(m.id, `unsupported client method: ${m.method}`);
      }
    }

    child.stderr.on("data", guarded((chunk) => {
      const text = chunk.toString();
      stderrTail = (stderrTail + text).slice(-2000);
      fs.appendFileSync(logFile, text, "utf8");
    }));

    child.on("error", (err) => {
      const hint = err.code === "ENOENT"
        ? "grok not found on PATH — install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash"
        : err.message;
      try { appendLog(logFile, `Spawn error: ${hint}`); } catch {}
      rejectAllPending(new Error(hint));
      finish({ status: "failed", errorMessage: hint, sessionId: null, rawOutput: "" });
    });

    child.on("close", guarded((code, signal) => {
      childClosed = true;
      rejectAllPending(new Error(`grok exited (${code === null ? `signal ${signal}` : `code ${code}`})`));
      if (settled) return;
      // The prompt already returned. Its stopReason is the authoritative verdict
      // and the awaiting flow is guaranteed to settle, so exiting promptly after
      // a turn is normal shutdown — not an incomplete run.
      if (phase === "done") return;
      const rawOutput = answer.join("").trim();
      if (timedOut) {
        finish({ status: "stalled", errorMessage: `Timed out after ${Math.round(args.timeoutMs / 1000)}s`, sessionId: acpSessionId, rawOutput });
      } else if (code !== 0) {
        // A nonzero exit is a failure even when partial answer chunks arrived;
        // rawOutput still carries whatever was received.
        const msg = code === null ? `signal ${signal}` : `exit ${code}`;
        finish({ status: "failed", errorMessage: stderrTail.trim() || msg, sessionId: acpSessionId, rawOutput });
      } else {
        // Exit 0 before the prompt returned is an incomplete protocol run, not
        // a success — the answer never arrived.
        finish({
          status: "failed",
          errorMessage: `grok exited during ${phase} without returning a prompt result`,
          sessionId: acpSessionId,
          rawOutput,
        });
      }
    }));

    // ── ACP conversation ─────────────────────────────────────────────────────
    (async () => {
      try {
        phase = "initialize";
        const init = await rpc("initialize", {
          protocolVersion: ACP_PROTOCOL_VERSION,
          clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
        });

        const negotiated = init?.protocolVersion;
        if (negotiated !== undefined && (typeof negotiated !== "number" || negotiated < 1)) {
          finish({
            status: "failed",
            errorMessage: `grok negotiated an unsupported ACP protocol version: ${JSON.stringify(negotiated)}`,
            sessionId: null,
            rawOutput: "",
          });
          return;
        }
        appendLog(logFile, `ACP protocol version negotiated: ${negotiated ?? "(not reported)"}`);

        // ACP authentication is lazy: an agent that is already logged in serves
        // session/new directly. Authenticating up front because `authMethods`
        // is non-empty breaks builds that advertise methods without
        // implementing the RPC, so only authenticate when a session is actually
        // refused for auth reasons.
        const authMethods = Array.isArray(init?.authMethods) ? init.authMethods : [];
        const authRequired = (error) => {
          const code = error?.code;
          if (code === -32000 || code === 401) return true;
          return /auth|unauthor|credential|login|api[_ -]?key/i.test(
            String(error?.message ?? "")
          );
        };
        const newSession = () => rpc("session/new", { cwd, mcpServers: [] });
        const newSessionWithAuth = async () => {
          try {
            return await newSession();
          } catch (error) {
            if (authMethods.length === 0 || !authRequired(error)) throw error;
            const ids = authMethods.map((method) => method?.id).filter(Boolean);
            // Only methods that complete without human interaction. Falling back
            // to an arbitrary advertised method can start a browser OAuth flow
            // that blocks headlessly until the deadline.
            const methodId =
              (process.env.XAI_API_KEY && ids.includes("xai.api_key") ? "xai.api_key" : null) ??
              (ids.includes("cached_token") ? "cached_token" : null);
            if (!methodId) {
              throw new Error(
                `grok requires authentication and advertised no non-interactive method (${ids.join(", ") || "none"}) — run 'grok login' or set XAI_API_KEY`
              );
            }
            phase = "authenticate";
            await rpc("authenticate", { methodId });
            appendLog(logFile, `Authenticated via ${methodId}`);
            phase = "session";
            return newSession();
          }
        };

        // Resume with session/load when a prior session id is given; fall back to
        // a fresh session if this build doesn't support load.
        phase = "session";
        if (args.resume) {
          try {
            await rpc("session/load", { sessionId: args.resume, cwd, mcpServers: [] });
            acpSessionId = args.resume;
            appendLog(logFile, `Resumed session ${args.resume}`);
          } catch {
            resumeFellBack = true;
            appendLog(logFile, `session/load unsupported or failed — starting a fresh session`);
            const s = await newSessionWithAuth();
            acpSessionId = s?.sessionId || null;
          }
        } else {
          const s = await newSessionWithAuth();
          acpSessionId = s?.sessionId || null;
        }

        if (!acpSessionId) {
          finish({ status: "failed", errorMessage: "no sessionId returned by grok", sessionId: null, rawOutput: "" });
          return;
        }
        appendLog(logFile, `Session: ${acpSessionId}`);

        // session/load replays the prior conversation as session/update
        // notifications; discard that history so rawOutput is only this turn's
        // answer.
        answer.length = 0;
        toolCalls = 0;
        lastChunkAt = 0;

        // Grok reads AGENTS.md and the shared .agents/skills tree natively, so
        // it can see cc-suite's Claude-facing skills too. Refuse the hand-back
        // in the prompt. See lib/delegation-boundary.mjs.
        phase = "prompt";
        const result = await rpc("session/prompt", {
          sessionId: acpSessionId,
          prompt: [{ type: "text", text: withDelegationBoundary(args.prompt) }],
        });
        phase = "done";

        if (timedOut) return; // the deadline path (close handler) finishes as stalled
        // Streamed chunks can trail the prompt response — drain before killing.
        await drainAnswer();
        if (timedOut || settled) return;
        const rawOutput = answer.join("").trim();
        const stop = result?.stopReason;
        appendLog(logFile, `Prompt returned (stopReason=${stop || "?"}, ${toolCalls} tool call(s))`);
        // Only an end-of-turn stop is a full completion; limit stops and
        // refusals carry partial output but must not report success.
        if (stop === "end_turn" || stop === "endTurn") {
          finish({ status: "completed", sessionId: acpSessionId, rawOutput });
        } else if (stop === undefined) {
          // Older builds omit stopReason. An answer is the evidence the turn
          // really completed; without one this is a malformed response.
          if (rawOutput) {
            appendLog(logFile, "stopReason missing — treating as end_turn (older grok build)");
            finish({ status: "completed", sessionId: acpSessionId, rawOutput });
          } else {
            finish({ status: "failed", errorMessage: "grok returned no stopReason and no answer", sessionId: acpSessionId, rawOutput });
          }
        } else if (stop === "cancelled" || stop === "canceled") {
          finish({ status: "stalled", errorMessage: `grok stopReason=${stop}`, sessionId: acpSessionId, rawOutput });
        } else if (stop === "refusal") {
          finish({ status: "failed", errorMessage: "grok refused the request (stopReason=refusal)", sessionId: acpSessionId, rawOutput });
        } else if (stop === "max_tokens" || stop === "max_turn_requests") {
          finish({ status: "failed", errorMessage: `grok stopped at a limit (stopReason=${stop}) — the answer may be truncated`, sessionId: acpSessionId, rawOutput });
        } else {
          finish({ status: "failed", errorMessage: `grok returned an unrecognized stopReason: ${JSON.stringify(stop)}`, sessionId: acpSessionId, rawOutput });
        }
      } catch (e) {
        if (timedOut || settled) return;
        finish({
          status: "failed",
          errorMessage: typeof e === "object" && e?.message ? e.message : JSON.stringify(e),
          sessionId: acpSessionId,
          rawOutput: answer.join("").trim(),
        });
      }
    })();
  });
}

async function runForeground(cwd, args) {
  const jobId = generateJobId(args.kind);
  activeJobId = jobId;
  const logFile = createJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;
  const deadlineAt = new Date(Date.now() + args.timeoutMs).toISOString();

  upsertJob(cwd, {
    id: jobId, kind: args.kind, status: "running",
    summary: args.summary || `${args.kind} task`,
    sessionId, pid: process.pid,
    pidStartedAt: readProcessStartTime(process.pid),
    startedAt: new Date().toISOString(), deadlineAt, logFile,
  });
  appendLog(logFile, `Starting ${args.kind} task (foreground, backend=grok/ACP)`);

  const result = await executeGrok(cwd, args, logFile);

  upsertJob(cwd, {
    id: jobId, status: result.status,
    threadId: result.sessionId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.sessionId || null,
    ...(typeof result.resumed === "boolean" ? { resumed: result.resumed } : {}),
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });

  const output = {
    jobId, status: result.status,
    threadId: result.sessionId || null,
    rawOutput: result.rawOutput || "",
    ...(typeof result.resumed === "boolean" ? { resumed: result.resumed } : {}),
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  };
  activeJobId = null; // job state and result are fully persisted
  process.stdout.write(JSON.stringify(output) + "\n");
  if (result.status !== "completed") process.exitCode = 1;
}

function runBackground(cwd, args) {
  const jobId = generateJobId(args.kind);
  activeJobId = jobId;
  const logFile = createJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;

  upsertJob(cwd, {
    id: jobId, kind: args.kind, status: "queued",
    summary: args.summary || `${args.kind} task`, sessionId, logFile,
  });
  appendLog(logFile, `Queued ${args.kind} task (background, backend=grok/ACP)`);

  const childArgv = [
    fileURLToPath(import.meta.url),
    "--kind", args.kind,
    "--model", args.model || "",
    "--effort", args.effort || "",
    "--sandbox", args.sandbox,
    "--timeout-ms", String(args.timeoutMs),
    "--session-id", sessionId || "",
    "--summary", args.summary || "",
  ];
  if (args.resume) childArgv.push("--resume", args.resume);
  childArgv.push("--", args.prompt);

  const child = spawn(process.execPath, childArgv, {
    cwd, detached: true, stdio: "ignore",
    env: { ...process.env, CODEX_TOOLKIT_BACKGROUND_JOB_ID: jobId },
  });

  // The worker records the running transition itself (with its own pid), so a
  // fast worker completion can never be overwritten with `running` here.
  child.on("error", (err) => {
    appendLog(logFile, `Background spawn error: ${err.message}`);
    upsertJob(cwd, {
      id: jobId, status: "failed",
      errorMessage: `Failed to start background worker: ${err.message}`,
      completedAt: new Date().toISOString(),
    });
  });
  child.unref();
  activeJobId = null; // the job now belongs to the detached worker

  process.stdout.write(JSON.stringify({ jobId, status: "queued", message: `Job ${jobId} started in background.` }) + "\n");
}

async function runBackgroundWorker(cwd, args, jobId) {
  const logFile = createJobLogFile(cwd, jobId);
  // Claim the queued job atomically — see codex-runner for the rationale.
  const claimed = claimJob(cwd, jobId, {
    status: "running", pid: process.pid,
    pidStartedAt: readProcessStartTime(process.pid),
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
  });
  if (!claimed) {
    appendLog(logFile, "Background worker exiting — job was cancelled before startup");
    return;
  }
  appendLog(logFile, "Background worker started (backend=grok/ACP)");

  const result = await executeGrok(cwd, args, logFile);

  upsertJob(cwd, {
    id: jobId, status: result.status,
    threadId: result.sessionId || null,
    completedAt: new Date().toISOString(),
    ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}),
  });
  writeJobFile(cwd, jobId, {
    rawOutput: result.rawOutput || "",
    threadId: result.sessionId || null,
    ...(typeof result.resumed === "boolean" ? { resumed: result.resumed } : {}),
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.prompt) {
    process.stderr.write("Error: no prompt provided. Use -- <prompt>\n");
    process.exit(1);
  }
  // An unrecognized sandbox must fail loudly: anything that is not exactly
  // "read-only" enables --always-approve, so a typo would silently escalate
  // permissions instead of restricting them.
  if (!VALID_SANDBOXES.has(args.sandbox)) {
    process.stderr.write(`Error: invalid --sandbox '${args.sandbox}' (expected read-only, workspace-write, or danger-full-access)\n`);
    process.exit(1);
  }
  const cwd = resolveWorkspaceRoot(process.cwd());

  const backgroundJobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID;
  if (backgroundJobId) {
    await runBackgroundWorker(cwd, args, backgroundJobId);
    return;
  }
  if (args.background) runBackground(cwd, args);
  else await runForeground(cwd, args);
}

main().catch((error) => {
  const message = error?.message || String(error);
  // A worker crash finalizes the job named by its environment; a foreground or
  // spawn-parent crash finalizes whatever job this process registered but had
  // not yet brought to a terminal state.
  const jobId = process.env.CODEX_TOOLKIT_BACKGROUND_JOB_ID || activeJobId || null;
  if (jobId) {
    try {
      upsertJob(resolveWorkspaceRoot(process.cwd()), {
        id: jobId,
        status: "failed",
        errorMessage: message,
        completedAt: new Date().toISOString(),
      });
    } catch {
      // State unreachable — the structured output below is the only signal.
    }
  }
  process.stdout.write(JSON.stringify({
    jobId,
    status: "failed",
    error: message,
  }) + "\n");
  process.stderr.write(`Error: ${message}\n`);
  process.exitCode = 1;
});
