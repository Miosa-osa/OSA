---
name: email-security
description: "Analyze suspicious email headers and attachments without opening active content, distinguish trusted authentication results and plan mail defenses. Use for phishing triage, email security, spoofed sender or SPF DKIM DMARC evidence."
category: security
version: "1.0.200"
triggers:
  - "email security"
  - "phishing triage"
  - "spoofed email"
  - "dmarc"
tools:
  - file_read
  - file_write
  - shell_execute
---

# Email Security

## Workflow

1. Preserve raw EML and hash; never follow links or render remote content during triage.
2. Extract selected headers using the bundled parser. Read the worked example for trust boundaries.
3. Identify the receiving organization's trusted authentication service before interpreting Authentication-Results. Attacker-supplied headers can lie.
4. Compare visible sender, envelope identity, DKIM signing domain and documented alignment results; auth pass alone does not establish harmless content.
5. Hash attachments without execution, record duplicate headers and parsing anomalies, and pass samples to sandbox-triage when needed.
6. Propose narrow mail controls, test known good mail and the offending sample, and document rollback and delivery impact.

## Worked example and prerequisites

Read [references/workflow.md](references/workflow.md) before execution. Use only registered OSA tools named in the frontmatter; command examples run through `shell_execute`. Check `command -v` for each external executable on the actual target. Optional packages, external collectors and vendor accounts are not bundled or presumed installed.

## Evidence and completion

Return scope, prerequisites, exact checks, observed results, evidence paths, limitations, remediation, rollback and retest status. Mark unavailable checks as blocked or unverified. Preserve original evidence and report redacted copies where needed. Work within the authorized environment; do not silently expand to external targets.

## Sources

Original OSA workflow and examples. Primary references are linked in the bundled workflow reference, so they remain available when this skill is installed separately. No third-party skill collection or rule pack is vendored.
