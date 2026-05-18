import { spawnSync } from "node:child_process";

export function resolveWorkspaceRoot(cwd) {
  const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
    cwd,
    encoding: "utf8",
    stdio: "pipe",
  });
  if (result.status === 0 && result.stdout.trim()) {
    return result.stdout.trim();
  }
  return cwd;
}
