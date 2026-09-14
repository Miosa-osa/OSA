---
name: network-defense
description: "Review network exposure, firewall policy and IDS evidence, then validate defensive changes with permitted and denied traffic controls. Use for network defense, segmentation, Suricata rules, firewall review or packet capture triage."
category: security
version: "1.0.200"
triggers:
  - "network defense"
  - "network segmentation"
  - "suricata"
  - "firewall review"
tools:
  - file_read
  - file_write
  - shell_execute
  - cyber_defense
---

# Network Defense

## Workflow

1. Map required flows: source, destination, protocol, port and owner. Inventory listeners and actual firewall policy without changing it.
2. Compare exposure against the map; distinguish listening interfaces from remotely reachable services.
3. For offline IDS analysis, read the Suricata workflow and verify the binary, config and packet fixture exist.
4. Validate both suspicious and allowed traffic; record capture visibility, rule versions and loss counters.
5. Prepare minimal policy changes with an out-of-band recovery path and exact rollback. Retest the denied path and permitted health checks after changes.
6. Do not claim offline detection proves inline blocking or complete network visibility.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
