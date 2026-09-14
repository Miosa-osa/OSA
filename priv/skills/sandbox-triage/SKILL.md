---
name: sandbox-triage
description: "Triage suspicious files with static metadata and bounded scanning, and distinguish malware detonation from safe application attack labs. Use for sandbox triage, suspicious attachments, YARA scanning or malware analysis preparation."
category: security
version: "1.0.200"
triggers:
  - "sandbox triage"
  - "suspicious file"
  - "malware triage"
  - "yara scan"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Sandbox Triage

## Workflow

1. Identify whether the request is static sample triage, malware detonation, or an OSA application simulation. They require different isolation.
2. Preserve hashes and custody; treat filenames, archives and parser outputs as untrusted input.
3. Read the static workflow. Do not execute samples, enable macros, upload confidential samples or use untrusted compiled YARA rules.
4. Bound scanner time and input size; scan trusted source-form rules with benign and matching fixtures. An empty match set is inconclusive.
5. Actual malware detonation requires a separately provisioned disposable VM, isolated network, no host shares/credentials and monitoring. This skill does not provision or claim such a VM.
6. Report static indicators and confidence separately from observed behavior. OSA cyber_defense runs only fixed application fixtures and is not a malware sandbox.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
