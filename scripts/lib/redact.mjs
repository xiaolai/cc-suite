// Redaction for third-party text that reaches a user-visible hook decision.
//
// The input is simultaneously the reviewer's own prose and whatever a
// subprocess printed, so there are two opposing failure modes: leaking a
// credential into the transcript, and mangling the sentence that explains why
// the user's work was blocked. Every rule below is shaped by that tension, and
// each one exists because the alternative was observed to fail.

// Provider key/token shapes (OpenAI, xAI, Anthropic, GitHub, Slack, AWS, Google).
// AWS and Google keys carry no separator after the prefix — AKIAIOSFODNN7EXAMPLE,
// AIzaSy… — so only the prefixes that do have one may require it.
const PROVIDER_TOKEN_RE =
  /\b(?:(?:sk|xai|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs])[-_]|AKIA|ASIA|AIza)[A-Za-z0-9_-]{8,}/g;

const BEARER_RE = /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi;

const SECRET_NAME =
  "api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|" +
  "client[_-]?secret|secret|password|passwd|token|authorization";

// `name = value`, `"name": "value"`, `name: value`.
//
// Separator: one optional quote, then ONE whitespace run. An earlier form used
// `\s*["']?\s*`, whose two whitespace runs either side of an optional quote can
// be split n+1 ways across a run of n spaces that is never followed by `:` or
// `=` — quadratic on input this module does not get to bound, because
// truncation happens after redaction.
//
// Value: the quoted alternatives come first and may span spaces. A quoted
// alternative that excluded whitespace made `password: "must be 8 chars"` fall
// through to the bare branch, which captured `"must`, redacted it, and left a
// dangling quote in the middle of the sentence.
const SECRET_ASSIGNMENT_RE = new RegExp(
  `\\b(${SECRET_NAME})\\b(["']?\\s*[:=]\\s*)("[^"]*"|'[^']*'|[^\\s,;)\\]}]+)`,
  "gi"
);

const MIN_QUOTED_SECRET = 4;
const MIN_BARE_SECRET = 8;
// An unquoted run at least this long, following a secret-ish name, is an opaque
// value rather than an English word. Set above the longest words that plausibly
// appear here in prose ("not-provided", "configuration") and below the shortest
// credentials observed leaking ("supersecretvalue", "deadbeefcafebabe").
const OPAQUE_BARE_LENGTH = 16;

function looksLikeCredential(value) {
  const quoted = /^(["']).*\1$/s.test(value);
  const bare = quoted ? value.slice(1, -1) : value;
  if (!bare || bare === "[redacted]" || /^Bearer\b/i.test(bare)) return false;

  if (quoted) {
    // Credentials do not contain whitespace. A quoted phrase after a
    // secret-ish name is the reviewer describing a rule ("password: 'must be
    // at least 8 chars'"), and redacting it inverts the block reason.
    if (/\s/.test(bare)) return false;
    return bare.length >= MIN_QUOTED_SECRET;
  }

  // Unquoted. Requiring a digit here spared every all-alphabetic secret —
  // `password = correcthorsebatterystaple` passed through verbatim. Length is
  // what separates an opaque run from the words that legitimately follow a
  // secret-ish name in prose: `missing`, `required`, `undefined`.
  if (bare.length < MIN_BARE_SECRET) return false;
  return /\d/.test(bare) || bare.length >= OPAQUE_BARE_LENGTH;
}

export function redactSecrets(text) {
  return String(text ?? "")
    .replace(PROVIDER_TOKEN_RE, "[redacted]")
    .replace(BEARER_RE, "Bearer [redacted]")
    .replace(SECRET_ASSIGNMENT_RE, (match, name, sep, value) =>
      looksLikeCredential(value) ? `${name}${sep}[redacted]` : match
    );
}
