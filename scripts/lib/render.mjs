function severityRank(severity) {
  switch (severity) {
    case "critical": return 0;
    case "high": return 1;
    case "medium": return 2;
    default: return 3;
  }
}

function escapeMarkdownCell(value) {
  return String(value ?? "")
    .replace(/\|/g, "\\|")
    .replace(/\r?\n/g, " ")
    .trim();
}

function pushJobDetails(lines, job, options = {}) {
  lines.push(`- ${job.id} | ${job.status} | ${job.kindLabel ?? job.kind}`);
  if (job.summary) lines.push(`  Summary: ${job.summary}`);
  if (job.phase) lines.push(`  Phase: ${job.phase}`);
  if (options.showElapsed && job.elapsed) lines.push(`  Elapsed: ${job.elapsed}`);
  if (options.showDuration && job.duration) lines.push(`  Duration: ${job.duration}`);
  if (job.threadId) lines.push(`  Thread ID: ${job.threadId}`);
  if (job.threadId) lines.push(`  Continue: /continue ${job.threadId}`);
  if ((job.status === "queued" || job.status === "running") && options.showCancelHint) {
    lines.push(`  Cancel: /codex-toolkit:cancel ${job.id}`);
  }
  if (job.status !== "queued" && job.status !== "running" && options.showResultHint) {
    lines.push(`  Result: /codex-toolkit:result ${job.id}`);
  }
  if (job.progressPreview?.length) {
    lines.push("  Progress:");
    for (const line of job.progressPreview) {
      lines.push(`    ${line}`);
    }
  }
}

export function renderStatusReport(report) {
  const lines = [
    "# Codex Toolkit Status",
    "",
    `Review gate: ${report.config.stopReviewGate ? "enabled" : "disabled"}`,
    "",
  ];

  if (report.running.length > 0) {
    lines.push("## Active Jobs");
    lines.push("");
    lines.push("| Job | Kind | Status | Phase | Elapsed | Thread ID | Summary |");
    lines.push("| --- | --- | --- | --- | --- | --- | --- |");
    for (const job of report.running) {
      lines.push(
        `| ${escapeMarkdownCell(job.id)} | ${escapeMarkdownCell(job.kindLabel)} | ${escapeMarkdownCell(job.status)} | ${escapeMarkdownCell(job.phase ?? "")} | ${escapeMarkdownCell(job.elapsed ?? "")} | ${escapeMarkdownCell(job.threadId ?? "")} | ${escapeMarkdownCell(job.summary ?? "")} |`
      );
    }
    lines.push("");
    for (const job of report.running) {
      pushJobDetails(lines, job, { showElapsed: true, showCancelHint: true });
    }
    lines.push("");
  }

  if (report.latestFinished) {
    lines.push("## Latest Finished");
    pushJobDetails(lines, report.latestFinished, {
      showDuration: true,
      showResultHint: true,
    });
    lines.push("");
  }

  if (report.recent.length > 0) {
    lines.push("## Recent Jobs");
    for (const job of report.recent) {
      pushJobDetails(lines, job, {
        showDuration: true,
        showResultHint: true,
      });
    }
    lines.push("");
  } else if (report.running.length === 0 && !report.latestFinished) {
    lines.push("No jobs recorded yet.", "");
  }

  if (report.needsReview) {
    lines.push(
      "The stop-time review gate is enabled.",
      "Ending the session will trigger a Codex adversarial review.",
      ""
    );
  }

  return `${lines.join("\n").trimEnd()}\n`;
}

export function renderJobResult(job, storedJob) {
  const threadId = storedJob?.threadId ?? job.threadId ?? null;
  const rawOutput = storedJob?.result?.rawOutput ?? storedJob?.rawOutput ?? "";

  if (rawOutput) {
    const output = rawOutput.endsWith("\n") ? rawOutput : `${rawOutput}\n`;
    if (!threadId) return output;
    return `${output}\nThread ID: ${threadId}\nContinue: /continue ${threadId}\n`;
  }

  const lines = [
    `# ${job.summary ?? "Codex Result"}`,
    "",
    `Job: ${job.id}`,
    `Status: ${job.status}`,
    `Kind: ${job.kindLabel ?? job.kind}`,
  ];

  if (threadId) {
    lines.push(`Thread ID: ${threadId}`);
    lines.push(`Continue: /continue ${threadId}`);
  }
  if (job.summary) lines.push(`Summary: ${job.summary}`);
  if (job.errorMessage) {
    lines.push("", job.errorMessage);
  } else {
    lines.push("", "No captured result payload was stored for this job.");
  }

  return `${lines.join("\n").trimEnd()}\n`;
}

export function renderCancelReport(job) {
  const lines = [
    "# Codex Cancel",
    "",
    `Cancelled ${job.id}.`,
    "",
  ];
  if (job.summary) lines.push(`- Summary: ${job.summary}`);
  if (job.kind) lines.push(`- Kind: ${job.kind}`);
  lines.push("- Check `/codex-toolkit:status` for the updated queue.");
  return `${lines.join("\n").trimEnd()}\n`;
}

export function renderSetupReport(report) {
  const lines = [
    "# Codex Toolkit Setup",
    "",
    `Status: ${report.ready ? "ready" : "needs attention"}`,
    "",
    "Checks:",
    `- node: ${report.node}`,
    `- codex CLI: ${report.codex}`,
    `- auth: ${report.auth}`,
    `- review gate: ${report.reviewGateEnabled ? "enabled" : "disabled"}`,
    "",
  ];

  if (report.nextSteps.length > 0) {
    lines.push("Next steps:");
    for (const step of report.nextSteps) {
      lines.push(`- ${step}`);
    }
  }

  return `${lines.join("\n").trimEnd()}\n`;
}

export function renderAuditFindings(findings) {
  if (!findings || findings.length === 0) return "No findings.\n";

  const sorted = [...findings].sort(
    (a, b) => severityRank(a.severity) - severityRank(b.severity)
  );

  const lines = [
    "| File:Line | Severity | Title | Body | Recommendation |",
    "| --- | --- | --- | --- | --- |",
  ];

  for (const f of sorted) {
    const lineRange = f.line_start
      ? f.line_end && f.line_end !== f.line_start
        ? `:${f.line_start}-${f.line_end}`
        : `:${f.line_start}`
      : "";
    lines.push(
      `| ${escapeMarkdownCell(f.file)}${lineRange} | ${escapeMarkdownCell(f.severity)} | ${escapeMarkdownCell(f.title)} | ${escapeMarkdownCell(f.body)} | ${escapeMarkdownCell(f.recommendation)} |`
    );
  }

  return `${lines.join("\n")}\n`;
}
