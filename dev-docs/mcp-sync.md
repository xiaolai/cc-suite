# Dev note: syncing Claude MCP servers into Codex and agy

Date: 2026-07-14

## Context

Claude Code reads project MCP servers from `.mcp.json`:

```json
{
  "mcpServers": {
    "@hypothesi/tauri-mcp-server": {
      "command": "npx",
      "args": ["@hypothesi/tauri-mcp-server"]
    }
  }
}
```

Codex CLI does not read `.mcp.json`; it reads `[mcp_servers.<name>]` tables in
`.codex/config.toml`. Antigravity CLI (`agy`) also does not read `.mcp.json`; it
reads workspace servers from `.agents/mcp_config.json` (or the user-managed
global `~/.gemini/config/mcp_config.json`). Codex requires the server name to
match:

```text
^[a-zA-Z0-9_-]+$
```

TOML quoting is not enough. A key such as
`[mcp_servers."@hypothesi/tauri-mcp-server"]` is valid TOML syntax but still
fails Codex MCP startup because the parsed server name contains `@` and `/`.

## Supported command

Run this from the target project in Claude Code:

```text
/cc-suite:sync-mcp
```

The historical command remains available:

```text
/cc-suite:bridge-mcp
```

Both commands run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

The bridge is idempotent. It rewrites only its sentinel block in
`.codex/config.toml` and refreshes the agy projection only when its provenance
file shows that cc-suite owns the generated file.

Codex projection:

```toml
# >>> cc-suite-mcp >>>
[mcp_servers.hypothesi-tauri-mcp-server]
# Claude MCP name: @hypothesi/tauri-mcp-server
command = "npx"
args = ["@hypothesi/tauri-mcp-server"]
# <<< cc-suite-mcp <<<
```

Name normalization replaces runs of characters outside the Codex grammar with
`-`, trims leading/trailing `-` and `_`, and falls back to `mcp-server` if a
name contains no usable characters. Collisions after normalization are
reported as errors rather than silently merging two Claude servers.

`codex-cli` is intentionally skipped: it is the Claude-side registration that
lets Claude invoke Codex and must not be mirrored back into Codex. It remains in
the agy projection because agy can use it for agy → Codex delegation. The
`claude-code` server is added to the agy projection so agy can delegate back to
Claude. Remote Claude fields `url` and `httpUrl` are translated to agy's
`serverUrl`. Environment variable names are documented as Codex comments, but
secret values are never copied into `.codex/config.toml`.

The generated `.agents/mcp_config.json` is ignored by default because MCP
definitions may contain secrets or machine-specific paths. A user-managed agy
config without cc-suite provenance is never overwritten; resolve the conflict
manually before rerunning the bridge.

Restart Codex or agy after syncing. Project MCP configuration is loaded at
session startup.

## Regression coverage

The integration suite covers scoped package names and dotted names, verifies
that all emitted Codex tables use safe names, checks that the original Claude
name is retained as a comment, and exercises agy projection idempotency,
provenance, conflict refusal, and unbridge cleanup:

```bash
bash tests/integration.sh
npm test
```
