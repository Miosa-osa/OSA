---
name: siem-operations
description: "Validate SIEM ingestion, parsing, alert routing and retention with synthetic canaries and timestamp evidence. Use for SIEM operations, missing events, alert pipeline outages, duplicate events or detection delivery checks."
category: security
version: "1.0.200"
triggers:
  - "siem operations"
  - "missing events"
  - "alert pipeline"
  - "ingestion health"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Siem Operations

## Workflow

1. Map producer, collector, parser, index, query, alert and destination; identify which stages are actually accessible.
2. Record expected volume, source coverage and ingestion delay. Read the synthetic canary workflow.
3. Test a harmless uniquely identified event through the authorized test pipeline and trace every stage.
4. Compare event time with receipt time; inspect parse failures, deduplication, rate limits and clock skew.
5. Run one alerting fixture and one benign control, preserving query version and delivery receipt. A search hit does not prove alert delivery.
6. Roll back changed rules/pipelines on regressions; distinguish restored ingestion from recovered historical gaps.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
