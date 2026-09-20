import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test, { before, after } from "node:test";
import assert from "node:assert/strict";

import { makeTempDir, cleanupDir, isolateEnv } from "./helpers.mjs";
import { listJobs, upsertJob } from "../scripts/lib/state.mjs";

const HOOK = fileURLToPath(
  new URL("../scripts/session-lifecycle-hook.mjs", import.meta.url)
);

// The hook resolves state from the environment; isolate so an ambient
// CLAUDE_PLUGIN_DATA / session id from the developer's own session cannot
// redirect these fixtures.
let restoreEnv;
before(() => {
  restoreEnv = isolateEnv();
});
after(() => {
  restoreEnv?.();
});

function runSessionEnd(workspace, sessionId) {
  return spawnSync(process.execPath, [HOOK, "SessionEnd"], {
    cwd: workspace,
    input: JSON.stringify({
      hook_event_name: "SessionEnd",
      cwd: workspace,
      session_id: sessionId,
    }),
    encoding: "utf8",
    env: { ...process.env },
  });
}

test("SessionEnd drops terminal jobs for the ending session", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "done-1",
      kind: "audit",
      status: "completed",
      sessionId: "sess-a",
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(listJobs(workspace), []);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionEnd leaves other sessions' jobs untouched", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "other-1",
      kind: "audit",
      status: "running",
      sessionId: "sess-b",
      pid: 999999999,
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);
    const jobs = listJobs(workspace);
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].id, "other-1");
    assert.equal(jobs[0].status, "running");
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionEnd drops an active job whose process is already gone", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "dead-1",
      kind: "audit",
      status: "running",
      sessionId: "sess-a",
      pid: 999999999, // not a live pid
      pidStartedAt: "Mon Jan  1 00:00:00 2020",
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(listJobs(workspace), []);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionEnd retains a queued job with no PID and marks it cancelled", () => {
  const workspace = makeTempDir();
  try {
    upsertJob(workspace, {
      id: "queued-1",
      kind: "audit",
      status: "queued",
      sessionId: "sess-a",
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);
    const jobs = listJobs(workspace);
    assert.equal(jobs.length, 1, "a job that could not be terminated must stay visible");
    assert.equal(jobs[0].status, "cancelled");
    assert.match(jobs[0].errorMessage, /no recorded PID/);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionEnd never signals a live PID it cannot prove is the job's own", () => {
  const workspace = makeTempDir();
  // A long-lived process standing in for an unrelated program that inherited a
  // recycled PID. The hook must not kill it.
  const bystander = spawnSync(process.execPath, [
    "-e",
    `const { spawn } = require('node:child_process');
     const c = spawn(process.execPath, ['-e', 'setTimeout(()=>{},60000)'], { detached: true, stdio: 'ignore' });
     c.unref();
     process.stdout.write(String(c.pid));`,
  ], { encoding: "utf8" });
  const pid = Number(bystander.stdout.trim());
  try {
    assert.ok(Number.isSafeInteger(pid) && pid > 0, "failed to start bystander");
    upsertJob(workspace, {
      id: "recycled-1",
      kind: "audit",
      status: "running",
      sessionId: "sess-a",
      pid,
      pidStartedAt: "Mon Jan  1 00:00:00 2020", // deliberately stale identity
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);

    // The bystander must still be alive: a mismatched start time proves the PID
    // was recycled, so it belongs to someone else and must never be signalled.
    let alive = true;
    try {
      process.kill(pid, 0);
    } catch (error) {
      alive = error?.code === "EPERM";
    }
    assert.equal(alive, true, "hook killed a process it could not prove was its own");
  } finally {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
    cleanupDir(workspace);
  }
});

test("SessionEnd does not signal a live PID recorded without process identity", () => {
  const workspace = makeTempDir();
  const bystander = spawnSync(process.execPath, [
    "-e",
    `const { spawn } = require('node:child_process');
     const c = spawn(process.execPath, ['-e', 'setTimeout(()=>{},60000)'], { detached: true, stdio: 'ignore' });
     c.unref();
     process.stdout.write(String(c.pid));`,
  ], { encoding: "utf8" });
  const pid = Number(bystander.stdout.trim());
  try {
    upsertJob(workspace, {
      id: "legacy-1",
      kind: "audit",
      status: "running",
      sessionId: "sess-a",
      pid, // no pidStartedAt: written by a cc-suite that predates identity tracking
    });
    const result = runSessionEnd(workspace, "sess-a");
    assert.equal(result.status, 0, result.stderr);

    let alive = true;
    try {
      process.kill(pid, 0);
    } catch (error) {
      alive = error?.code === "EPERM";
    }
    assert.equal(alive, true, "hook signalled a PID it could not verify");

    const jobs = listJobs(workspace);
    assert.equal(jobs.length, 1, "an unsignalled job must stay visible");
    assert.equal(jobs[0].status, "cancelled");
    assert.match(jobs[0].errorMessage, /process-identity/);
  } finally {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
    cleanupDir(workspace);
  }
});

// ─── SessionStart: prune the dead codex-cli MCP registration ─────────────────
// cc-suite ≤2.0.1 registered `codex mcp-server` as `codex-cli` in .mcp.json.
// That subcommand no longer exists in Codex CLI, so Claude Code reports a failed
// MCP connection every session until the entry is gone. The SessionStart hook is
// what heals projects that were bridged by an older version, so it is tested
// here rather than left to the plugin's own upgrade path.
const PLUGIN_ROOT = fileURLToPath(new URL("..", import.meta.url));

function runSessionStart(workspace) {
  return spawnSync(process.execPath, [HOOK, "SessionStart"], {
    cwd: workspace,
    input: JSON.stringify({
      hook_event_name: "SessionStart",
      cwd: workspace,
      session_id: "sess-start",
    }),
    encoding: "utf8",
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  });
}

const DEAD_ENTRY = { type: "stdio", command: "codex", args: ["mcp-server"] };

function writeMcpJson(workspace, servers) {
  fs.writeFileSync(
    path.join(workspace, ".mcp.json"),
    JSON.stringify({ mcpServers: servers }, null, 2) + "\n"
  );
}

function readMcpJson(workspace) {
  return JSON.parse(fs.readFileSync(path.join(workspace, ".mcp.json"), "utf8"));
}

test("SessionStart removes the dead codex-cli entry and keeps other servers", () => {
  const workspace = makeTempDir();
  try {
    writeMcpJson(workspace, {
      "codex-cli": DEAD_ENTRY,
      keep: { type: "stdio", command: "cmd" },
    });
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    const doc = readMcpJson(workspace);
    assert.deepEqual(Object.keys(doc.mcpServers), ["keep"]);
    // The removal only reaches Claude Code next session, so it must say so.
    assert.match(JSON.parse(result.stdout).systemMessage, /Restart Claude Code/);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart deletes a .mcp.json that held only the dead entry", () => {
  const workspace = makeTempDir();
  try {
    writeMcpJson(workspace, { "codex-cli": DEAD_ENTRY });
    assert.equal(runSessionStart(workspace).status, 0);
    assert.equal(fs.existsSync(path.join(workspace, ".mcp.json")), false);
    // Nothing left to do, and nothing to announce.
    const again = runSessionStart(workspace);
    assert.equal(again.status, 0);
    assert.equal(again.stdout, "");
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart leaves a codex-cli entry cc-suite did not write alone", () => {
  const workspace = makeTempDir();
  try {
    const mine = { type: "stdio", command: "my-codex-wrapper", args: ["serve"] };
    writeMcpJson(workspace, { "codex-cli": mine });
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(readMcpJson(workspace).mcpServers["codex-cli"], mine);
    // No removal happened, so claiming one would be a lie.
    assert.equal(result.stdout, "");
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart leaves an unparseable .mcp.json untouched", () => {
  const workspace = makeTempDir();
  try {
    const mcpPath = path.join(workspace, ".mcp.json");
    fs.writeFileSync(mcpPath, "{not json");
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(mcpPath, "utf8"), "{not json");
    assert.equal(result.stdout, "");
  } finally {
    cleanupDir(workspace);
  }
});

// ─── SessionStart: re-point a stale skills symlink ───────────────────────────
// The link carries the version-stamped cache path, so every plugin update makes
// it stale in every project, and it dangles once that version leaves the cache —
// silently removing cc-suite's skills. The sweep repairs a machine on demand;
// this is what keeps a single project from rotting in between.
function makeCacheLink(workspace, version, { create = true } = {}) {
  const cache = path.join(
    workspace, "home/.claude/plugins/cache/xiaolai/cc-suite", version,
    "skills/cc-suite"
  );
  if (create) fs.mkdirSync(cache, { recursive: true });
  const linkDir = path.join(workspace, ".claude/skills");
  fs.mkdirSync(linkDir, { recursive: true });
  const link = path.join(linkDir, "cc-suite");
  fs.symlinkSync(cache, link);
  return { cache, link };
}

const WANTED_SKILLS = path.join(PLUGIN_ROOT, "skills", "cc-suite");

test("SessionStart re-points a skills link that names an older cache version", () => {
  const workspace = makeTempDir();
  try {
    const { link } = makeCacheLink(workspace, "0.9.9");
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readlinkSync(link), WANTED_SKILLS);
    assert.match(JSON.parse(result.stdout).systemMessage, /re-pointed/);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart re-points a dangling skills link", () => {
  const workspace = makeTempDir();
  try {
    const { link } = makeCacheLink(workspace, "0.0.1", { create: false });
    assert.equal(fs.existsSync(link), false, "fixture should dangle");
    assert.equal(runSessionStart(workspace).status, 0);
    assert.equal(fs.readlinkSync(link), WANTED_SKILLS);
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart leaves a skills link outside the plugin cache alone", () => {
  const workspace = makeTempDir();
  try {
    // /cc-suite:init from a local-scope install writes exactly this on purpose.
    const dev = path.join(workspace, "devcheckout/cc-suite/skills/cc-suite");
    fs.mkdirSync(dev, { recursive: true });
    const linkDir = path.join(workspace, ".claude/skills");
    fs.mkdirSync(linkDir, { recursive: true });
    const link = path.join(linkDir, "cc-suite");
    fs.symlinkSync(dev, link);
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readlinkSync(link), dev);
    assert.equal(result.stdout, "");
  } finally {
    cleanupDir(workspace);
  }
});

test("SessionStart leaves an authored skills directory alone", () => {
  const workspace = makeTempDir();
  try {
    const real = path.join(workspace, ".claude/skills/cc-suite/mine");
    fs.mkdirSync(real, { recursive: true });
    assert.equal(runSessionStart(workspace).status, 0);
    assert.equal(fs.existsSync(real), true);
    assert.equal(
      fs.lstatSync(path.join(workspace, ".claude/skills/cc-suite")).isSymbolicLink(),
      false
    );
  } finally {
    cleanupDir(workspace);
  }
});

test("both self-heals in one session emit exactly one JSON object", () => {
  const workspace = makeTempDir();
  try {
    writeMcpJson(workspace, { "codex-cli": DEAD_ENTRY });
    const { link } = makeCacheLink(workspace, "0.9.9");
    const result = runSessionStart(workspace);
    assert.equal(result.status, 0, result.stderr);
    // Two messages, ONE object: SessionStart's stdout contract is a single JSON
    // object, so a second write would corrupt the first.
    const lines = result.stdout.trim().split("\n").filter(Boolean);
    assert.equal(lines.length, 1, `expected one JSON line, got:\n${result.stdout}`);
    const { systemMessage } = JSON.parse(lines[0]);
    assert.match(systemMessage, /codex-cli MCP registration/);
    assert.match(systemMessage, /re-pointed/);
    assert.equal(fs.readlinkSync(link), WANTED_SKILLS);
  } finally {
    cleanupDir(workspace);
  }
});
