---
name: attack-simulation
description: "Run cyber defense attack simulations against isolated lab targets, compare detection gaps, apply a lab patch and rerun to prove defenses work. Use for purple team exercises, simulate attacks, sandbox targets, or test a fix."
category: security
version: "1.0.200"
triggers:
  - "simulate attacks"
  - "purple team"
  - "attack simulation"
  - "prove defenses work"
tools:
  - file_read
  - file_write
  - shell_execute
  - cyber_defense
---

# Attack Simulation

## Workflow

1. Call `cyber_defense` with `{"action":"scenarios"}`; select an implemented scenario, not a real address.
2. Check Docker availability and the preinstalled `python:3.12-slim` image. Missing dependencies are blocked prerequisites, never a successful simulation.
3. Run the worked loop below. Preserve the complete JSON evidence, including baseline attack and benign behavior.
4. Compare the attack result, benign control, and detector events before and after remediation. A stopped attack alone is insufficient if normal use breaks.
5. Run `remediation: ineffective` as a failed-fix control. It must not count as verified.
6. Report cleanup status and every unsupported production assumption. The embedded detector demonstrates lab behavior, not deployed SIEM coverage.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
