---
name: log-analysis
description: "Normalize and correlate security logs into an evidence-backed timeline while preserving timestamps and parse errors. Use for log analysis, auth failures, event timelines, JSONL triage or suspicious application logs."
category: security
version: "1.0.200"
triggers:
  - "log analysis"
  - "security timeline"
  - "auth logs"
  - "parse security logs"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Log Analysis

## Workflow

1. Preserve the original file and SHA-256, record source timezone and export range.
2. Inspect the schema and volume before choosing fields. Read the bounded JSONL helper workflow.
3. Count malformed records, missing timestamps and source gaps separately from events.
4. Normalize UTC for comparisons while keeping original timestamp and source identifier. Avoid ordering ambiguous timestamps as certain.
5. Compare suspicious patterns with normal traffic and maintenance. Link each conclusion back to original line numbers.
6. Save query/transform version, totals, evidence and uncertainty; redact secrets only in derived reports.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
