---
name: dfir-incident-toolkit
description: "Digital forensics and incident response workflow: read-only evidence acquisition with SHA-256 integrity records, typed acquisition outcomes (collected/cancelled/permission-denied/failed), containment previews with digests and approval receipts, rollback planning before execution, and artifact redaction at collection time. Use when responding to a suspected compromise, acquiring disk/memory/log evidence, planning containment actions with approval gates, or structuring a case file for an incident. Derived from the T3MP3ST platform's DFIR toolkit (Apache-2.0)."
category: security
triggers:
  - "dfir"
  - "digital forensics"
  - "incident response"
  - "evidence acquisition"
  - "containment"
  - "compromise response"
tools:
  - file_read
  - file_grep
  - file_glob
  - file_write
  - dir_list
  - shell_execute
---

# DFIR — Incident Toolkit

Derived from T3MP3ST's `src/dfir/toolkit.ts` (Apache-2.0). Two disciplines make
DFIR evidence usable: **read-only acquisition** (never alter what you investigate)
and **approved containment** (never change a system without a preview, a digest,
and a receipt).

## 1. Acquisition — read-only, verified, typed

- Artifacts are collected by read-only collectors; the toolkit NEVER writes to
  the target during acquisition.
- Every artifact becomes an evidence record: `id, caseId, targetId, name,
  source, collectedAt, receivedAt, sha256, sizeBytes, collector, transfer,
  verified, redactedMetadata`.
- Integrity: hash at collection, re-verify on receipt (`verified` flag). A
  mismatch is a finding about your own pipeline.
- Duplicate names within one acquisition are rejected — silent dedup loses
  evidence.
- Metadata is redacted at acquisition (`redactedMetadata`), not at report time.
- Outcomes are typed and final: `collected | cancelled | permission-denied |
  collection-failed`. `permission-denied` is a real result (record it, move on);
  it is not a retry candidate.

## 2. Containment — preview, digest, approval, receipt

Changing a compromised system is the most dangerous moment in IR. The pattern:

1. **Preview** the containment action first: `{caseId, targetId, actionId,
   summary, rollback, commands[]}` — the preview is hashed into a `digest`.
2. **Approval** is a separate record: `{receiptId, caseId, targetId, actionId,
   previewDigest, approvedBy, approvedAt, expiresAt}`. The approval binds to the
   EXACT digest of the previewed action — any change to the plan invalidates it.
3. **Execution checks the binding**: case/target/action IDs must match, the
   preview digest must match, the approval must not be expired, and `approvedAt`
   must precede execution start. Any mismatch → `denied` with
   `authorization-required`. No approval object at all → denied, always.
4. **Receipt** records the outcome: `completed | partial | cancelled | denied |
   failed`, with `completedSteps/totalSteps` and the rollback path attached.

The rollback plan is part of the preview — an action without a rollback plan is
not previewable, and therefore not approvable.

## 3. Standard acquisition targets (Linux)

| Evidence | Command sketch |
|---|---|
| Process list + hashes | `ps auxww > proc.txt; sha256sum proc.txt` |
| Open sockets | `ss -tunap > sockets.txt` |
| Login history | `last -F > last.txt; lastb -F > lastb.txt` |
| Cron/systemd persistence | `crontab -l`, `ls -la /etc/cron*`, `systemctl list-unit-files --state=enabled` |
| Bash history | `cat ~/.bash_history` (note: attacker-controlled after compromise) |
| File timeline | `find / -newer /ref/file -printf '%T@ %p\n' \| sort -n` |
| Memory (if available) | LiME or `avml` `[INSTALL]` — before anything else; memory is volatile |
| Disk image | `dc3dd`/`dd` with hashing `[INSTALL]` — to external storage, never the suspect disk |

Order matters: memory → volatile state → logs → disk. Every step read-only.

## 4. Case-file conventions

- One directory per case: `case-<id>/{evidence/,notes.md,timeline.jsonl,report.md}`.
- `timeline.jsonl`: one event per line `{ts, source, event, confidence}` — merge
  timestamps from all artifacts, note the source of each.
- Every evidence file gets its SHA-256 recorded at acquisition and re-verified
  before analysis (`sha256sum -c`).
- Chain of custody: who collected, when, from where, transferred how — the
  record fields in section 1 exist so this is never reconstructed from memory.

## 5. OSA-specific wiring

- `sha256sum` `[LOCAL]`, `ss`/`ps`/`last` `[LOCAL]` on this machine.
- Work read-only: prefer `file_read`/`file_grep` over anything that writes; if a
  copy is needed, copy TO your case directory, never write on the source.
- Containment on OSA's own host requires explicit operator approval — apply the
  preview/digest/receipt pattern even for "simple" fixes (isolate a container,
  revoke a key), because the approval record is the audit trail.

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/dfir/toolkit.ts`), Apache-2.0. Patterns described; no code copied.

Part of the offensive skill library — see also `evidence-vault-chain-of-custody`
for the finding-side vault and `opsec-operational-discipline` for engagement
noise discipline.