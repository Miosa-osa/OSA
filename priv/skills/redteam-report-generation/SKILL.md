---
name: redteam-report-generation
description: "Engagement report generation for red-team and pentest work: severity-ordered finding sections with verification status badges, evidence snippets with type labels, CVE/CWE cross-references, remediation guidance, mission metadata (status, phases, timestamps), markdown escaping for safe report rendering, and best-effort report writing that never breaks the engagement. Use when writing the final report for a security engagement, structuring findings for delivery, or generating status reports from a completed or in-progress mission. Derived from the T3MP3ST platform's auto-report generator (Apache-2.0)."
category: security
triggers:
  - "engagement report"
  - "pentest report"
  - "generate report"
  - "findings report"
  - "mission summary"
  - "deliverable report"
tools:
  - file_read
  - file_write
  - file_glob
  - file_grep
  - dir_list
  - shell_execute
---

# Red-Team Report Generation

Derived from T3MP3ST's `src/reporting/auto-report.ts` (Apache-2.0). A report is
the engagement's deliverable — structure it so severity, verification status,
and evidence are visible at a glance, and write it best-effort so reporting
never breaks the mission.

## 1. Report skeleton

```markdown
# Engagement Report: <mission name>

- **Status**: <status>
- **Final phase**: <phase>
- **Started**: <ISO-8601>
- **Completed**: <ISO-8601 or —>

## Targets

- <address> (<type>, zone: <zone>, status: <status>)

## Findings (<total>)

### CRITICAL (n)
- **[CRITICAL] <title>** — ✅ verified | ⚠️ unverified (<provenance>)
  - Description: ...
  - CVE: CVE-XXXX-YYYY
  - CWE: CWE-ZZZ
  - Remediation: ...
  - Evidence (output): `<snippet ≤180 chars, whitespace-collapsed>`

### HIGH (n)
...

## Methodology
<what was done, in order, with tool versions>
```

## 2. The rules that make the report honest

- **Severity ordering is fixed**: critical → high → medium → low → info. Every
  finding appears under its severity heading with a count.
- **Verification status is stamped on every finding**: `✅ verified` when the
  provenance gate passed, `⚠️ unverified (<provenance: none|context>)` when it
  did not. An unverified finding is still reported — it is just labeled. Never
  silently promote prose to verified.
- **Asserted-vs-derived severity**: if the finding asserted a severity that
  differs from the derived one, show both (`(asserted: high)`). Disagreement is
  information, not noise.
- **Evidence snippets are bounded**: ≤3 per finding, ≤180 chars each,
  whitespace-collapsed, type-labeled (`output`, `command`, `response`, `log`).
  The full evidence lives in the vault; the report shows the receipt.
- **CVE/CWE cross-references** when known — they are the reader's link to
  public context.
- **Remediation on every actionable finding** — a finding without a fix is a
  complaint, not a report entry.
- **Empty is a result**: zero findings renders "no vulnerabilities found" —
  never an empty section that reads like a generation bug.

## 3. Markdown escaping

Escape markdown metacharacters in ALL interpolated content (`\`, backtick,
`*`, `_`, `{}`, `[]`, `()`, `#`, `+`, `-`, `.`, `!`, `|`, `>`) so target names,
titles, and evidence snippets cannot inject formatting (or worse, links) into
the report. Escape at render time, every time.

## 4. Best-effort writing

- Report generation must never break the engagement: if the reports directory
  cannot be written, skip with a note — do not crash, do not retry forever.
- Write to a `reports/` directory in the case folder; one file per mission,
  named with the mission id and completion date.
- Regeneration is idempotent: building the report again from the same vault
  state produces the same content.

## 5. OSA-specific wiring

- Assemble from the case JSONL logs (`evidence-vault-chain-of-custody` format)
  with a small Python script `[LOCAL]`.
- Deliver the report path to the operator; never paste the full report into
  chat — the file is the deliverable.
- Sanitize before delivery per `opsec-operational-discipline` (operator
  hostname, usernames, internal paths out).

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/reporting/auto-report.ts`), Apache-2.0. Patterns described; no code copied.

Part of the offensive skill library — see also `evidence-vault-chain-of-custody`
(the vault the report is built from) and `penetration-testing`.