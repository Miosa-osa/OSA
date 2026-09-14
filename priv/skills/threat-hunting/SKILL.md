---
name: threat-hunting
description: "Investigate a testable cyber defense hypothesis across host, identity and network evidence. Use for threat hunting, hidden persistence, unusual logins or finding adversary behavior without an existing alert."
category: security
version: "1.0.200"
triggers:
  - "threat hunting"
  - "hunt persistence"
  - "unusual logins"
  - "hunt hypothesis"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Threat Hunting

## Workflow

1. Write a falsifiable hypothesis, affected population, time window and observable evidence.
2. Inventory available telemetry and field coverage; distinguish unobserved from absent.
3. Query a benign baseline and suspicious cohort with the same logic. Read the worked hunt before broadening scope.
4. Correlate across independent sources; deduplicate by source event identity, not just timestamp.
5. Classify findings as confirmed, suspicious or inconclusive and document disconfirming evidence.
6. Convert a repeatable finding into a detection with positive and benign regression fixtures; escalate confirmed compromise through incident-response.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
