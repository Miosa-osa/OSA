---
name: incident-response
description: "Investigate suspected compromise, preserve incident evidence, build a timeline and plan containment, recovery and verification. Use for incident response, account takeover, suspicious host activity or recovery after an attack."
category: security
version: "1.0.200"
triggers:
  - "incident response"
  - "suspected compromise"
  - "account takeover"
  - "incident recovery"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Incident Response

## Workflow

1. Record incident scope, time window, source systems, owner, and observed impact. Separate confirmed evidence from hypotheses.
2. Preserve volatile observations and exported logs in a case directory; use hashes and collection timestamps. Read the acquisition example before collecting.
3. Correlate identities, hosts and time; record clock skew and missing evidence. Do not treat an empty log as proof of no activity.
4. Propose containment with concrete target, expected service impact and rollback. Execute changes only within the user's authorized scope; preserve recoverable access.
5. Remove the confirmed cause, restore from validated state, rotate affected credentials where indicated, and monitor for recurrence.
6. Verify normal service and the previously abused path; document evidence gaps and follow-up owners.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
