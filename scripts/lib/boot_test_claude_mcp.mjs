#!/usr/bin/env node
// cc-suite: boot-and-handshake smoke test for the pinned claude-octopus.
//
// Spawns `npx -y claude-octopus@<pin>` exactly the way `.codex/config.toml`
// will, sends a single MCP `initialize` request over stdin, and verifies the
// server responds with a well-formed `serverInfo`. Then kills the subprocess.
//
// Used by /cc-suite:update, /cc-suite:doctor, and tests/integration.sh to
// catch "pin published but actually broken" — semver compliance does not
// imply the package boots on this user's machine.
//
// Usage:
//   node boot_test_claude_mcp.mjs              # read pin from claude-octopus-pin.txt
//   node boot_test_claude_mcp.mjs 1.1.10       # explicit version
//   TIMEOUT_MS=15000 node boot_test_claude_mcp.mjs
//
// Exit codes: 0 = handshake ok, 1 = handshake failed/timed out.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PIN_FILE = resolve(HERE, "claude-octopus-pin.txt");
function parseTimeoutMs(raw) {
  if (raw === undefined || raw === "") return 30000;
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    console.error(
      `✗ invalid TIMEOUT_MS ${JSON.stringify(raw)}: expected a positive integer of milliseconds`
    );
    process.exit(1);
  }
  return parsed;
}
const TIMEOUT_MS = parseTimeoutMs(process.env.TIMEOUT_MS);

function readPin() {
  return readFileSync(PIN_FILE, "utf8").trim();
}

// The exact-semver grammar from semver.org. An empty or loose pin would make
// npx resolve an unintended release instead of the pinned one.
const EXACT_SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/;

const version = process.argv[2] || readPin();
if (!EXACT_SEMVER.test(version)) {
  console.error(
    `✗ invalid claude-octopus pin ${JSON.stringify(version)}: expected an exact semver version`
  );
  process.exit(1);
}
const target = `claude-octopus@${version}`;

const INIT_REQUEST = JSON.stringify({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "cc-suite-boot-test", version: "0.0.1" },
  },
});

const child = spawn("npx", ["-y", target], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});

let stdout = "";
let stderr = "";
let settled = false;

const timer = setTimeout(() => {
  if (settled) return;
  settled = true;
  finish(1, `timed out after ${TIMEOUT_MS}ms waiting for ${target} to respond`);
}, TIMEOUT_MS);

function finish(code, message) {
  clearTimeout(timer);
  if (code === 0) {
    console.log(`✓ ${message}`);
  } else {
    console.error(`✗ ${message}`);
    if (stderr.trim()) console.error(`  stderr: ${stderr.trim().split("\n").slice(0, 4).join(" | ")}`);
  }
  // Only exit once the child is gone: exit immediately if it already died,
  // otherwise SIGTERM, escalate to SIGKILL after a grace period, and exit on
  // its exit event — so a SIGTERM-resistant child is not orphaned.
  if (child.exitCode !== null || child.signalCode !== null) {
    process.exit(code);
  }
  const killTimer = setTimeout(() => {
    try { child.kill("SIGKILL"); } catch {}
    // Last resort if no exit event ever arrives (e.g. spawn never happened).
    setTimeout(() => process.exit(code), 500);
  }, 500);
  child.once("exit", () => {
    clearTimeout(killTimer);
    process.exit(code);
  });
  try { child.kill("SIGTERM"); } catch {}
}

child.on("error", (err) => {
  if (settled) return;
  settled = true;
  finish(1, `failed to spawn npx: ${err.message}`);
});

child.on("exit", (code, signal) => {
  if (settled) return;
  settled = true;
  finish(1, `${target} exited before responding (code=${code}, signal=${signal})`);
});

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

child.stdout.on("data", (chunk) => {
  stdout += chunk.toString();
  // Process complete lines.
  let nl;
  while ((nl = stdout.indexOf("\n")) !== -1) {
    const line = stdout.slice(0, nl).trim();
    stdout = stdout.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue; // non-JSON lines (status messages) are fine to skip
    }
    if (msg.jsonrpc === "2.0" && msg.id === 1 && msg.result) {
      if (settled) return;
      settled = true;
      // Validate the full InitializeResult shape, not just a truthy name — a
      // server that omits its version or protocol version did not complete a
      // well-formed handshake.
      const result = msg.result;
      const serverInfo = result.serverInfo ?? {};
      const wellFormed =
        typeof result.protocolVersion === "string" &&
        result.protocolVersion.length > 0 &&
        typeof result.capabilities === "object" &&
        result.capabilities !== null &&
        typeof serverInfo.name === "string" &&
        serverInfo.name.length > 0 &&
        typeof serverInfo.version === "string" &&
        serverInfo.version.length > 0;
      if (!wellFormed) {
        finish(
          1,
          `${target} returned a malformed initialize result: ${line.slice(0, 200)}`
        );
        return;
      }
      finish(
        0,
        `${target} booted; server reports ${serverInfo.name}@${serverInfo.version} (protocol ${result.protocolVersion})`
      );
      return;
    }
    if (msg.jsonrpc === "2.0" && msg.id === 1 && msg.error) {
      if (settled) return;
      settled = true;
      finish(1, `${target} returned MCP error: ${JSON.stringify(msg.error)}`);
      return;
    }
  }
});

child.stdin.write(INIT_REQUEST + "\n");
