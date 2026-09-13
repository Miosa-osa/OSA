---
name: arsenal-tool-validation
description: "Tool-arsenal validation and risk gating for offensive engagements: risk-tier classification of tools (safe/active/intrusive/credential/dangerous), approval gates where intrusive tools are inert until approved (approve-once-then-free or pre-authorized allowlists), fail-safe denial for unattended runs, loud audited warnings for the hottest actions, egress scope enforcement, and pre-engagement availability checks. Use when preparing a toolset before an engagement, deciding which tools need operator approval, building approval gates into security tooling, or validating that an arsenal is present and scoped before a run. Derived from the T3MP3ST platform's arsenal approval system (Apache-2.0)."
category: security
triggers:
  - "tool validation"
  - "arsenal"
  - "approval gate"
  - "risk tier"
  - "pre-engagement check"
  - "tool gating"
tools:
  - file_read
  - file_write
  - shell_execute
  - dir_list
  - web_search
---

# Arsenal — Tool Validation & Risk Gating

Derived from T3MP3ST's `src/arsenal/` (Apache-2.0). The principle: **an
intrusive tool is INERT until a human has approved it** — and the hottest
actions fire a loud, audited warning every single time, even when approved.

## 1. Risk tiers

| Tier | Meaning | Gated? | Warning every use? |
|---|---|---|---|
| `safe` | read-only probes, passive recon | no | no |
| `active` | touches the target (scans, fuzzing) | no (scope-gated) | no |
| `intrusive` | exploits, state-changing actions | **yes** | no |
| `credential` | password attacks, credential stuffing | **yes** | **yes** |
| `dangerous` | full post-ex frameworks, destructive ops | **yes** | **yes** |

Undefined tier → treat as `safe` for gating but verify by inspection; a tool
that mutates state must never sit in `safe`.

## 2. The approval gate

Two ways a gated tool becomes approved:

1. **Interactive:** the first time the operator reaches for the tool, the system
   asks. A yes approves the TOOL (by name) for the rest of the session —
   "approve once, then free". Every use is still audited.
2. **Pre-authorized allowlist:** for headless/unattended runs (benchmarks,
   automated hunts), the operator hands in an allowlist up front. Listed tools
   run free; anything off-list DENIES.

**FAIL-SAFE rule:** a gated tool that is neither pre-approved nor interactively
approvable (no approver wired) is DENIED. An unattended run never silently fires
an exploit because nobody was there to say no.

**Spicy warnings:** `credential`/`dangerous` tools fire a loud, audited,
non-blocking WARNING on EVERY use even after approval — the operator should
always SEE what the agent is about to do.

## 3. Egress scope — the always-on gate

Approval and scope are separate gates:

- The egress scope gate refuses any action targeting an out-of-scope host,
  REGARDLESS of tool approval. Approval says "you may use this tool"; scope says
  "you may point it there". Both must pass.
- Scope is a list written at engagement start (see `penetration-testing`); the
  gate checks targets against the list, not against the operator's claims.
- An operator can extend gating to cover built-in probes too (T3MP3ST's
  `GATE_BUILTINS` pattern) — when in doubt, gate more, not less.

## 4. Pre-engagement availability check

Before the engagement starts, validate the arsenal:

```bash
# for each tool the engagement plan names:
command -v nmap >/dev/null && echo "OK nmap" || echo "MISSING nmap"
```

- Record `[LOCAL]` (present, with version), `[INSTALL]` (absent but one-command
  installable), or `[UPSTREAM-REF]` (needs keys/infra).
- A tool that is `[INSTALL]` gets installed and re-verified BEFORE the
  engagement, not mid-hunt.
- Version-pin what matters: an old `nuclei` template set or a stale `nmap`
  script DB changes results. Record versions in the engagement log.
- The plan-vs-arsenal diff is a deliverable: every tool the plan names must be
  `[LOCAL]` at start time, or the plan changes.

## 5. Audit trail

Every gated-tool event is audited: `{tool, risk, decision(approved|denied),
actor, at, warning?}`. Denials include the reason (not-approved /
out-of-scope / no-approver). The audit log is append-only JSONL in the case
directory — it is the evidence that the gate worked.

## 6. OSA-specific wiring

- OSA's own permission system is the approval gate: tools that prompt the
  operator are the interactive path; never bypass a permission prompt to "save
  time" — that is the fail-safe rule violated.
- `command -v` + `--version` `[LOCAL]` for the availability check.
- Keep the audit JSONL next to the engagement evidence (see
  `evidence-vault-chain-of-custody`).

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/arsenal/approval.ts`, `src/arsenal/catalog.ts`), Apache-2.0. Patterns
described; no code copied.

Part of the offensive skill library — see also `penetration-testing` and
`opsec-operational-discipline`.