---
name: evidence-vault-chain-of-custody
description: "Evidence management for security engagements: chain-of-custody records with SHA-256 integrity, the provenance-strict verification gate (a finding is only 'verified' when backed by real tool output, never prose), credential redaction for any outward-facing surface, CVSS-to-severity scoring, and authorized retest workflows with typed probe dispositions. Use when structuring findings/evidence storage for a pentest or bug-bounty engagement, deciding what evidence makes a claim reportable, redacting captured credentials from reports, or re-testing fixed vulnerabilities. Derived from the T3MP3ST platform's evidence vault (Apache-2.0)."
category: security
triggers:
  - "evidence vault"
  - "chain of custody"
  - "finding verification"
  - "provenance"
  - "credential redaction"
  - "retest finding"
  - "severity scoring"
tools:
  - file_read
  - file_glob
  - file_grep
  - file_write
  - file_edit
  - dir_list
  - shell_execute
---

# Evidence Vault & Chain of Custody

Derived from T3MP3ST's `src/evidence/` (Apache-2.0). The core principle: **a
claim is only as strong as its provenance. Prose is not evidence.**

## 1. The provenance-strict verification gate

A finding may be marked `verified` ONLY when backed by real tool output. The
gate is honest by construction — it never invents provenance, and it states why
it blocked:

- **Tool evidence types** that count: `output`, `command`, `response`,
  `request`, `log`, `file` — each with non-empty content. A human note or a
  narrative paragraph is `context`, not proof.
- **Zero tool evidence → FAIL** with reason: "no tool-output evidence —
  provenance-strict requires a finding be backed by real tool output, not prose".
- **Severity must be earned:** asserting `critical` or `high` with zero evidence
  of any kind is an overclaim and fails the gate.
- **Typed provenance:** `none` (no evidence at all), `context` (notes only),
  `tool` (real output). Only `tool` passes.

Apply the same gate to your own work: before you report a finding to the
operator, list the exact tool receipt (command output, HTTP pair, log line) that
backs it. No receipt → report it as a lead, not a confirmed finding.

## 2. Chain-of-custody records

Every acquired artifact gets a record with these fields:

```
id, caseId, targetId, name, source, collectedAt, receivedAt,
sha256, sizeBytes, collector, transfer, verified, redactedMetadata
```

Rules the record enforces:

- `sha256` is computed at acquisition and re-verified on read (`verified` flag)
  — integrity is checked, not assumed.
- `collectedAt` (when the artifact was taken) and `receivedAt` (when the vault
  accepted it) are separate timestamps; a gap is part of the record.
- Duplicate artifact names within one acquisition are rejected — a vault that
  silently dedups is a vault that loses evidence.
- Metadata is redacted at acquisition time (`redactedMetadata`), not later.
- Acquisition outcomes are typed: `collected | cancelled | permission-denied |
  collection-failed`. Permission errors are their own outcome — never retried
  as if they were transient.

## 3. Credential redaction — secrets never leave the process

Captured credentials are the highest-risk data in any engagement:

- The outward-facing shape of a credential strips the raw `secret` and replaces
  it with a boolean `secretCaptured` flag. All non-sensitive metadata (user,
  target, protocol, source) is kept.
- This applies to EVERY outward surface: API responses, reports, prompts to
  other models, chat output. If the surface can be read by someone else, it
  gets the redacted shape.
- Never "temporarily" include a secret in output with intent to redact later —
  redaction happens at the boundary, by construction.

## 4. Severity scoring

| CVSS | Severity |
|---|---|
| ≥ 9.0 | critical |
| ≥ 7.0 | high |
| ≥ 4.0 | medium |
| ≥ 0.1 | low |
| 0 | info |

Severity weights for scoring runs: critical 10, high 7.5, medium 5, low 2.5,
info 0. Severity is derived from CVSS or demonstrated impact — never from how
exciting the finding feels.

## 5. Authorized retest workflow

Re-testing a previously-reported finding after a fix:

- Statuses: `fixed | still_vulnerable | unverifiable`.
- Each attempt records a probe disposition: `present` (vuln still observable),
  `absent` (fix confirmed), `inconclusive` (probe could not tell — retryable).
- Attempts are bounded (`maxAttempts`), timestamped, and carry the exact tool +
  arguments used. Provenance is explicit: `authorized-tool-retest`.
- `unverifiable` is a real outcome — report it as such instead of guessing.

## 6. OSA-specific wiring

- Store evidence under a scratchpad or case directory, never in the repo.
- Hash with `sha256sum` `[LOCAL]`; keep the JSONL log format from
  `offensive-osint` (`run_id`, `ts`, `tool`, `artifact`, `sha256`, `next`).
- Findings that fail the gate go to the operator as leads with the reason
  attached — the gate's refusal text is the report.

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/evidence/index.ts`, `src/evidence/gate.ts`, `src/evidence/retest.ts`),
Apache-2.0. Patterns described; no code copied.

Part of the offensive skill library — see also `penetration-testing` and
`redteam-multi-agent-orchestration`.