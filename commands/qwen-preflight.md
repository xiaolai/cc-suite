---
description: Check local Qwen Code readiness for the bounded review runner without sending a model prompt or inspecting credentials.
allowed-tools:
  - Bash
---

# Qwen Review Preflight

## Step 1: Run the preflight script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-preflight.sh"
```

Parse the single JSON object. If `status` is `"error"`, skip to Step 3.

## Step 2: Display results

Display:

```markdown
## Qwen Review Preflight

**Status**: {status}
**Qwen version**: {qwen_version}
**Minimum supported version**: {minimum_version}
**Authentication**: not probed
**Sandbox provider**: {sandbox_provider}

### Runner guarantees

- Safe Mode
- Plan mode
- Qwen sandbox
- isolated temporary target copies
- explicit non-review tool denials and verified init tool surface
- zero tool-call budget for prompt-only reviews
- bounded `read_file` calls for declared targets
- stream-json completion validation
- exact-target read policy
- bounded session resume
```

`auth_mode` is deliberately `"not_probed"`: authentication requires a real
provider call, and preflight must not send an availability prompt. The first
real review reports an authentication/provider failure through the job result.

## Step 3: Handle errors

Report `error_code` and `error`, then apply the matching remedy:

- `qwen_not_found` — install Qwen Code and ensure `qwen` is on `PATH`.
- `qwen_version_unsupported` — upgrade to the reported minimum version or newer.
- `qwen_version_unparseable` — the installed binary did not return a usable version.
- `qwen_sandbox_unavailable` — install or configure sandbox-exec, Docker, or Podman.

Do not run the review runner when preflight returns `status: "error"`.
