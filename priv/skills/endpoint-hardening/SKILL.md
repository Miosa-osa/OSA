---
name: endpoint-hardening
description: "Assess host service permissions and defensive configuration, prepare reversible hardening and verify normal behavior plus attack resistance. Use for endpoint hardening, Linux service sandboxing, reducing privileges or securing a workstation."
category: security
version: "1.0.200"
triggers:
  - "endpoint hardening"
  - "linux hardening"
  - "service sandboxing"
  - "reduce privileges"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Endpoint Hardening

## Workflow

1. Inventory OS, service owner, exposure and required functionality before selecting controls.
2. Read the service assessment example; collect actual effective configuration and permissions.
3. Rank concrete excess privileges or writable trust paths; do not treat an automated score as exploit proof.
4. Prepare one change at a time with exact prior config, restart impact and rollback procedure.
5. Test in a disposable equivalent environment; require both restricted unsafe behavior and passing functional checks.
6. Report untested platform differences and preserve recovery access before any authorized host rollout.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
