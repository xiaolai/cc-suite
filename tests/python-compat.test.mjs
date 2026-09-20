import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

// cc-suite's Python runs under whatever `python3` the user has on PATH. On macOS
// that is often /usr/bin/python3 — 3.9 — where a PEP 604 union (`str | None`) or
// a subscripted builtin (`list[str]`) in a signature is EVALUATED at def time and
// raises TypeError, so the module fails to import.
//
// This is a tripwire, not a type checker. It exists because the failure is quiet
// where it matters: scripts/status.sh reads its classifier's exit code with
// stderr discarded, so an unimportable module looked like a confident answer
// until the codes were moved out of the 0-9 range. Either use the future import,
// or use typing.List/Dict/Optional as scripts/bridge_agents.py does.
const SCRIPTS = fileURLToPath(new URL("../scripts", import.meta.url));
const FUTURE = "from __future__ import annotations";

// Annotation positions only: `->` returns, and `name: type` in a def signature
// or a module-level annotation. Bare `a | b` expressions are not annotations.
const MODERN_ANNOTATION = [
  /->\s*[\w.\[\]"', ]*\|/, //            -> str | None
  /:\s*(?:list|dict|set|tuple|type|frozenset)\[/, // x: list[str]
  /->\s*(?:list|dict|set|tuple|type|frozenset)\[/, // -> dict[str, int]
];

function pythonFiles(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) => {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        return entry.name === "__pycache__" ? [] : pythonFiles(full);
      }
      return entry.name.endsWith(".py") ? [full] : [];
    });
}

test("every Python module importable on 3.9, or declares the future import", () => {
  const files = pythonFiles(SCRIPTS);
  assert.ok(files.length > 0, "no Python modules found under scripts/");

  const offenders = [];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    if (source.includes(FUTURE)) continue;
    const hit = source
      .split("\n")
      .map((line, i) => [i + 1, line])
      .find(([, line]) => MODERN_ANNOTATION.some((re) => re.test(line)));
    if (hit) {
      offenders.push(`${path.relative(SCRIPTS, file)}:${hit[0]}: ${hit[1].trim()}`);
    }
  }

  assert.deepEqual(
    offenders,
    [],
    `these modules use 3.10+ annotation syntax without "${FUTURE}", so they fail to import on Python 3.9:\n  ${offenders.join("\n  ")}`
  );
});
