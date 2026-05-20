# Privacy Policy — cc-suite

_Last updated: 2026-05-20_

cc-suite bridges three CLI tools (Claude Code, Codex CLI, Gemini CLI) so they share configuration. This policy describes the data cc-suite handles.

## What cc-suite reads

`AGENTS.md`, `.claude/`, `.codex/`, `.gemini/`, and `.mcp.json` in the projects you initialize with `/cc-suite:init` or operate on with other cc-suite commands. Hook events when the bridge mirrors them across the three CLIs.

## What cc-suite writes

Symlinks and configuration files inside `.claude/`, `.codex/`, `.gemini/`, and `.agents/` directories in your project — these are the bridge artifacts. A small marker file at `.codex/.cc-suite.provenance` records which artifacts cc-suite created.

## What cc-suite transmits

**Nothing of its own.** cc-suite does not maintain a backend, does not phone home, does not collect telemetry, does not register usage with any third party.

When you delegate via the Codex MCP server (or any of the three CLIs), your prompts and code go to whichever LLM provider you have configured (Anthropic, OpenAI, Google), under each provider's privacy terms and using **your own credentials**. cc-suite is the wiring, not the data path.

## Third parties

cc-suite itself contacts no third parties. Your existing relationships with the LLM providers you configure (Anthropic, OpenAI, Google) apply unchanged.

## Data deletion

There is no centralized data to delete on the maintainer's side. To remove cc-suite from a project: `/cc-suite:unbridge` followed by `claude plugin uninstall cc-suite@xiaolai`.

## Contact

For privacy questions or to report a discrepancy with this policy: **xiaolaiapple@gmail.com**.
