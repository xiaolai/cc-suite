"""Classify the `codex-cli` entry in a project's .mcp.json.

cc-suite used to register Codex CLI's own built-in MCP server under that key so
Claude could call Codex as an MCP tool. That server is gone: `codex mcp-server`
is no longer a subcommand (verified absent in codex-cli 0.155.1, where `codex
mcp` is the *manage external MCP servers* command group and has no `serve`).
`codex mcp-server` is now parsed as a prompt for the interactive TUI, so under
an MCP client's piped stdin it dies immediately:

    $ printf '<initialize>' | codex mcp-server
    Error: stdin is not a terminal          # exit 1

Claude Code therefore reports a failed MCP connection on every session in every
project that ran an older `/cc-suite:init`. Nothing in cc-suite ever needed the
entry: all Claude→Codex delegation goes through `codex exec` via
scripts/codex-runner.mjs (see commands/shared/codex-call.md).

This module is the single definition of "which codex-cli entries are cc-suite's
own dead registration". prune_codex_mcp.sh, diagnose.py and status.sh all
import it: the shape was previously spelled out in each of them plus the
session hook, and four spellings of one predicate is how they drift apart.
"""

from __future__ import annotations

ABSENT = "absent"
DEAD_BUILTIN = "dead_builtin"
DEAD_LEGACY_NPM = "dead_legacy_npm"
FOREIGN = "foreign"

DEAD = (DEAD_BUILTIN, DEAD_LEGACY_NPM)

SERVER_NAME = "codex-cli"

# Human-readable reason per classification, for callers that report to a user.
REASONS = {
    DEAD_BUILTIN: "`codex mcp-server` no longer exists in Codex CLI — the server fails to start",
    DEAD_LEGACY_NPM: "legacy npm Codex MCP package — unmaintained and no longer the delegation path",
    FOREIGN: "not a registration cc-suite wrote — left untouched",
}


def _basename(command: str) -> str:
    return command.rsplit("/", 1)[-1]


def classify(entry) -> str:
    """Classify one `mcpServers["codex-cli"]` value.

    `None` (the key is absent) is ABSENT. Anything cc-suite did not write is
    FOREIGN and must be left alone — the key is not reserved by fiat, and a
    hand-written wrapper that actually works is the user's to keep.
    """
    if entry is None:
        return ABSENT
    if not isinstance(entry, dict):
        return FOREIGN

    command = entry.get("command")
    if not isinstance(command, str):
        return FOREIGN
    raw_args = entry.get("args")
    args = raw_args if isinstance(raw_args, list) else []

    # The built-in server: `codex mcp-server`, however the binary is spelled on
    # PATH. Match the subcommand rather than the whole object so registrations
    # carrying an extra `env`/`type` key are still recognized as ours.
    if _basename(command) == "codex" and args[:1] == ["mcp-server"]:
        return DEAD_BUILTIN

    # The legacy npm shape written by cc-suite ≤0.2.12. Test the launcher *and*
    # the package: a substring test on the command alone would mislabel every
    # command merely containing "npx"/"npm" (wrappers, unrelated launchers).
    launcher = _basename(command) in ("npx", "npm")
    legacy_pkg = any(
        isinstance(a, str) and ("codex-mcp-server" in a or a.startswith("@openai/codex"))
        for a in args
    )
    if launcher and legacy_pkg:
        return DEAD_LEGACY_NPM

    return FOREIGN


def classify_document(doc) -> str | None:
    """Classify the codex-cli entry of a parsed .mcp.json document.

    Returns None when the document is not a shape cc-suite can reason about
    (top level or `mcpServers` is not an object) — callers must then leave the
    file alone rather than guess.
    """
    if not isinstance(doc, dict):
        return None
    servers = doc.get("mcpServers")
    if servers is None:
        return ABSENT
    if not isinstance(servers, dict):
        return None
    return classify(servers.get(SERVER_NAME))
