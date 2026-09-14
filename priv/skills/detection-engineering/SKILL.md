---
name: detection-engineering
description: "Build and validate cyber defense detection rules with malicious and benign fixtures, telemetry prerequisites and false positive controls. Use for Sigma rules, detection engineering, missing alerts or measuring detection coverage."
category: security
version: "1.0.200"
triggers:
  - "detection engineering"
  - "sigma rules"
  - "missing alerts"
  - "false positives"
tools:
  - file_read
  - file_write
  - shell_execute
  - cyber_defense
---

# Detection Engineering

## Workflow

1. Define the behavior, required log source, field mapping, and alert threshold before writing a rule.
2. Read `references/workflow.md` for an original Sigma-format example and controls. Check optional `sigma` CLI availability and installed backend; conversion is not execution.
3. Replay positive, benign, and missing-field fixtures against the actual chosen backend. Record observed alerts, not just query syntax validity.
4. Use `cyber_defense` to exercise embedded lab detection where relevant; never equate its alerts with a real SIEM alert.
5. Tune exclusions narrowly, rerun all fixtures, and retain rule version plus evidence. Roll back the rule if detection loss or false positives exceed the agreed threshold.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
