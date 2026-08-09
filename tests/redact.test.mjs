import test from "node:test";
import assert from "node:assert/strict";

import { redactSecrets } from "../scripts/lib/redact.mjs";

// This text reaches the user as the reason their work was blocked, so the two
// failure modes are equally real: leaking a credential, and destroying the
// sentence that explains the block. Both directions are asserted here.

test("provider key shapes are redacted, including the separator-less ones", () => {
  for (const key of [
    "sk-proj-abcdefghijklmnop",
    "xai-abcdefghijklmnop",
    "ghp_abcdefghijklmnop",
    "github_pat_abcdefghijklmnop",
    "xoxb-abcdefghijklmnop",
    "AKIAIOSFODNN7EXAMPLE",
    "ASIAIOSFODNN7EXAMPLE",
    "AIzaSyD-abcdefghijklmnop",
  ]) {
    const out = redactSecrets(`the key ${key} leaked`);
    assert.equal(out.includes(key), false, `${key} was not redacted`);
    assert.match(out, /\[redacted\]/);
  }
});

test("bearer tokens are redacted but the scheme is kept", () => {
  assert.equal(
    redactSecrets("Authorization: Bearer abcdefghijklmnopqrst"),
    "Authorization: Bearer [redacted]"
  );
});

test("all-alphabetic secrets are redacted", () => {
  // Requiring a digit in the value silently spared every one of these.
  for (const line of [
    "password = correcthorsebatterystaple",
    "api_key: abcdefghijklmnopqrst",
    "client_secret = supersecretvalue",
    "token = deadbeefcafebabe",
  ]) {
    assert.match(redactSecrets(line), /\[redacted\]/, `not redacted: ${line}`);
  }
});

test("digit-bearing opaque values are redacted", () => {
  assert.equal(
    redactSecrets("auth_token = QWxhZGRpbjpvcGVuc2VzYW1l"),
    "auth_token = [redacted]"
  );
  assert.equal(redactSecrets('"api_key": "sk1abc234def"'), '"api_key": [redacted]');
});

test("reviewer prose after a secret-ish name survives intact", () => {
  for (const line of [
    "api_key: missing from the schema",
    "token: undefined",
    "password: required",
    "secret: placeholder",
    "authorization: failed",
    "api_key: not-provided",
    "token = null",
  ]) {
    assert.equal(redactSecrets(line), line, `prose was mangled: ${line}`);
  }
});

test("a quoted multi-word phrase is prose, not a credential", () => {
  // The bare-value branch used to capture only `"must`, redact it, and leave a
  // dangling quote mid-sentence — inverting the meaning of the block reason.
  const line = 'password: "must be at least 8 chars" is the message';
  assert.equal(redactSecrets(line), line);

  const line2 = 'secret: "some value here"';
  assert.equal(redactSecrets(line2), line2);
});

test("a quoted single-token value is still redacted", () => {
  assert.equal(redactSecrets('password: "hunter2swordfish"'), "password: [redacted]");
  assert.equal(redactSecrets("token: 'abcdefgh'"), "token: [redacted]");
});

test("an already-redacted value is left alone", () => {
  assert.equal(redactSecrets("api_key: [redacted]"), "api_key: [redacted]");
});

test("redaction is linear on adversarial whitespace runs", () => {
  // `\s*["']?\s*` split a whitespace run n+1 ways, which is quadratic; the
  // input is unbounded here because truncation happens after redaction.
  const timeFor = (n) => {
    const input = `token${" ".repeat(n)}x`;
    const started = process.hrtime.bigint();
    redactSecrets(input);
    return Number(process.hrtime.bigint() - started) / 1e6;
  };
  timeFor(1000); // warm up the JIT so the ratio measures the algorithm
  const small = Math.max(timeFor(8000), 0.05);
  const large = timeFor(32000);
  // 4x the input. Linear ≈ 4x; quadratic ≈ 16x. Allow generous headroom for
  // scheduling noise while still failing loudly on quadratic behaviour.
  assert.ok(
    large < small * 10,
    `redaction looks super-linear: 8k=${small.toFixed(2)}ms 32k=${large.toFixed(2)}ms`
  );
  assert.ok(large < 100, `redaction took ${large.toFixed(2)}ms on 32k of whitespace`);
});

test("redaction handles non-string input without throwing", () => {
  assert.equal(redactSecrets(null), "");
  assert.equal(redactSecrets(undefined), "");
  assert.equal(redactSecrets(42), "42");
});
