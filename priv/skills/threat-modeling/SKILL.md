---
name: threat-modeling
description: "Build a concrete cyber defense threat model from assets, data flows and trust boundaries, then map controls to attack simulations and verification. Use for threat modeling, architecture security, abuse cases or designing defenses before deployment."
category: security
version: "1.0.200"
triggers:
  - "threat modeling"
  - "trust boundaries"
  - "abuse cases"
  - "architecture security"
tools:
  - file_read
  - file_write
  - shell_execute
  - cyber_defense
---

# Threat Modeling

## Workflow

1. Read the system architecture and identify assets, entry points, actors and trust boundaries. Record assumptions you cannot verify.
2. For each sensitive flow, construct a concrete misuse case with prerequisites, affected asset and observable failure.
3. Choose a control with an owner and verification method, not just a framework label.
4. Read the worked boundary example and map only supported behaviors to cyber_defense fixtures.
5. Test relevant implementation paths and benign behavior; prioritize residual risks with evidence.
6. Revisit the model when architecture or trust assumptions change. A successful generic lab does not validate the deployed application.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
