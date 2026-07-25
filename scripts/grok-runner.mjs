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
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import {
  generateJobId,
  upsertJob,
  writeJobFile,
  resolveJobLogFile,
} from "./lib/state.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";
import { withDelegationBoundary } from "./lib/delegation-boundary.mjs";

const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes — matches the other runners
const HEARTBEAT_MS = 30 * 1000;
const SIGKILL_GRACE_MS = 5 * 1000;
const ACP_PROTOCOL_VERSION = "1";

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

  let i = 2;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--kind" && argv[i + 1]) { args.kind = argv[++i]; }
    else if (arg === "--model" && argv[i + 1]) { args.model = argv[++i]; }
    else if (arg === "--effort" && argv[i + 1]) { args.effort = argv[++i]; }
    else if (arg === "--sandbox" && argv[i + 1]) { args.sandbox = argv[++i]; }
    else if (arg === "--resume" && argv[i + 1]) { args.resume = argv[++i]; }
    else if (arg === "--timeout-ms" && argv[i + 1]) {
      const n = Number(argv[++i]);
      if (Number.isFinite(n) && n > 0) args.timeoutMs = n;
    }
    else if (arg === "--background") { args.background = true; }
    else if (arg === "--session-id" && argv[i + 1]) { args.sessionId = argv[++i]; }
    else if (arg === "--summary" && argv[i + 1]) { args.summary = argv[++i]; }
    else if (arg === "--") { args.prompt = argv.slice(i + 1).join(" "); break; }
    i++;
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

    const child = spawn("grok", grokArgs, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"], // stdin: JSON-RPC out, stdout: JSON-RPC in
      env: { ...process.env },
    });

    const startedAt = Date.now();
    const pending = new Map();
    let nextId = 1;
    let buf = "";
    let stderrTail = "";
    const answer = [];
    let toolCalls = 0;
    let settled = false;
    let timedOut = false;
    let acpSessionId = args.resume || null;

    const send = (obj) => { try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch { /* child gone */ } };
    const rpc = (method, params) => new Promise((res, rej) => {
      const id = nextId++;
      pending.set(id, { res, rej });
      send({ jsonrpc: "2.0", id, method, params });
    });
    const respond = (id, result) => send({ jsonrpc: "2.0", id, result });
    const respondErr = (id, message) => send({ jsonrpc: "2.0", id, error: { code: -32601, message } });

    const heartbeat = setInterval(() => {
      appendLog(logFile, `…still running (${Math.round((Date.now() - startedAt) / 1000)}s elapsed, ${toolCalls} tool call(s))`);
    }, HEARTBEAT_MS);

    const deadline = setTimeout(() => {
      timedOut = true;
      appendLog(logFile, `Deadline exceeded (${Math.round(args.timeoutMs / 1000)}s) — cancelling and terminating`);
      if (acpSessionId) send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: acpSessionId } });
      child.kill("SIGTERM");
      setTimeout(() => { if (!settled) child.kill("SIGKILL"); }, SIGKILL_GRACE_MS);
    }, args.timeoutMs);

    function finish(result) {
      if (settled) return;
      settled = true;
      clearInterval(heartbeat);
      clearTimeout(deadline);
      try { child.kill(); } catch { /* already dead */ }
      resolve(result);
    }

    // ── ACP message dispatch (newline-delimited JSON-RPC) ────────────────────
    child.stdout.on("data", (chunk) => {
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
    });

    function handleNotification(m) {
      if (m.method !== "session/update") return;
      const u = m.params?.update || {};
      if (u.sessionUpdate === "agent_message_chunk") answer.push(u.content?.text ?? "");
      else if (u.sessionUpdate === "tool_call") { toolCalls++; appendLog(logFile, `tool_call: ${u.title || u.tool || u.toolCallId || "?"}`); }
    }

    // Grok mostly uses its own tools, but ACP lets it call back to the client for
    // permissions and file I/O. Honor the sandbox here.
    function handleAgentRequest(m) {
      if (m.method === "session/request_permission") {
        const opts = m.params?.options || [];
        const want = alwaysApprove ? /allow|approve|yes/i : /reject|deny|no/i;
        const pick = opts.find((o) => want.test(o.optionId || o.kind || o.name || "")) || opts[0];
        respond(m.id, { outcome: { outcome: "selected", optionId: pick?.optionId } });
      } else if (m.method === "fs/read_text_file") {
        try { respond(m.id, { content: fs.readFileSync(m.params.path, "utf8") }); }
        catch (e) { respondErr(m.id, String(e)); }
      } else if (m.method === "fs/write_text_file") {
        if (!alwaysApprove) { respondErr(m.id, "read-only: write denied"); return; }
        try { fs.writeFileSync(m.params.path, m.params.content ?? ""); respond(m.id, {}); }
        catch (e) { respondErr(m.id, String(e)); }
      } else {
        respondErr(m.id, `unsupported client method: ${m.method}`);
      }
    }

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderrTail = (stderrTail + text).slice(-2000);
      fs.appendFileSync(logFile, text, "utf8");
    });

    child.on("error", (err) => {
      const hint = err.code === "ENOENT"
        ? "grok not found on PATH — install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash"
        : err.message;
      appendLog(logFile, `Spawn error: ${hint}`);
      finish({ status: "failed", errorMessage: hint, sessionId: null, rawOutput: "" });
    });

    child.on("close", (code, signal) => {
      if (settled) return;
      const rawOutput = answer.join("").trim();
      if (timedOut) {
        finish({ status: "stalled", errorMessage: `Timed out after ${Math.round(args.timeoutMs / 1000)}s`, sessionId: acpSessionId, rawOutput });
      } else if (code !== 0 && !rawOutput) {
        const msg = code === null ? `signal ${signal}` : `exit ${code}`;
        finish({ status: "failed", errorMessage: stderrTail.trim() || msg, sessionId: acpSessionId, rawOutput });
      } else {
        finish({ status: "completed", sessionId: acpSessionId, rawOutput });
      }
    });

    // ── ACP conversation ─────────────────────────────────────────────────────
    (async () => {
      try {
        await rpc("initialize", {
          protocolVersion: ACP_PROTOCOL_VERSION,
          clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
        });

        // Resume with session/load when a prior session id is given; fall back to
        // a fresh session if this build doesn't support load.
        if (args.resume) {
          try {
            await rpc("session/load", { sessionId: args.resume, cwd, mcpServers: [] });
            acpSessionId = args.resume;
            appendLog(logFile, `Resumed session ${args.resume}`);
          } catch {
            appendLog(logFile, `session/load unsupported or failed — starting a fresh session`);
            const s = await rpc("session/new", { cwd, mcpServers: [] });
            acpSessionId = s?.sessionId || null;
          }
        } else {
          const s = await rpc("session/new", { cwd, mcpServers: [] });
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

        // Grok reads AGENTS.md and the shared .agents/skills tree natively, so
        // it can see cc-suite's Claude-facing skills too. Refuse the hand-back
        // in the prompt. See lib/delegation-boundary.mjs.
        const result = await rpc("session/prompt", {
          sessionId: acpSessionId,
          prompt: [{ type: "text", text: withDelegationBoundary(args.prompt) }],
        });

        if (timedOut) return; // the deadline path (close handler) finishes as stalled
        const rawOutput = answer.join("").trim();
        const stop = result?.stopReason;
        appendLog(logFile, `Prompt returned (stopReason=${stop || "?"}, ${toolCalls} tool call(s))`);
        // A cancelled/refused turn is not a successful completion.
        if (stop === "cancelled" || stop === "canceled") {
          finish({ status: "stalled", errorMessage: `grok stopReason=${stop}`, sessionId: acpSessionId, rawOutput });
        } else {
          finish({ status: "completed", sessionId: acpSessionId, rawOutput });
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
  const logFile = resolveJobLogFile(cwd, jobId);
  const sessionId = args.sessionId || process.env.CODEX_TOOLKIT_SESSION_ID || null;
  const deadlineAt = new Date(Date.now() + args.timeoutMs).toISOString();

  upsertJob(cwd, {
    id: jobId, kind: args.kind, status: "running",
    summary: args.summary || `${args.kind} task`,
    sessionId, pid: process.pid,
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
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });

  const output = {
    jobId, status: result.status,
    threadId: result.sessionId || null,
    rawOutput: result.rawOutput || "",
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  };
  process.stdout.write(JSON.stringify(output) + "\n");
  if (result.status !== "completed") process.exitCode = 1;
}

function runBackground(cwd, args) {
  const jobId = generateJobId(args.kind);
  const logFile = resolveJobLogFile(cwd, jobId);
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

  upsertJob(cwd, {
    id: jobId, status: "running", pid: child.pid,
    startedAt: new Date().toISOString(),
    deadlineAt: new Date(Date.now() + args.timeoutMs).toISOString(),
  });
  child.unref();

  process.stdout.write(JSON.stringify({ jobId, status: "queued", message: `Job ${jobId} started in background.` }) + "\n");
}

async function runBackgroundWorker(cwd, args, jobId) {
  const logFile = resolveJobLogFile(cwd, jobId);
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
    ...(result.errorMessage ? { error: result.errorMessage } : {}),
  });
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.prompt) {
    process.stderr.write("Error: no prompt provided. Use -- <prompt>\n");
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

main();
