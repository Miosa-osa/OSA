---
name: honeytokens-deception
description: "Honeytoken design and deployment for detecting intrusion attempts: token kinds (opaque, API-key-shaped, credential-shaped, beacon), lifecycle management (create, activate, rotate, revoke, cleanup), HMAC-signed trigger verification with nonce and replay protection, environment-scoped authorization, audit trails for every action, and alert-sink integration. Use when planting decoy credentials or artifacts to detect attackers, designing canary tokens for infrastructure or repos, or building detection alerting around deception assets. Derived from the T3MP3ST platform's honeytoken manager (Apache-2.0)."
category: security
triggers:
  - "honeytoken"
  - "canary token"
  - "deception"
  - "decoy credential"
  - "intrusion detection trap"
  - "breach detection"
tools:
  - file_read
  - file_write
  - file_edit
  - file_grep
  - shell_execute
  - web_search
---

# Honeytokens & Deception

Derived from T3MP3ST's `src/deception/honeytokens.ts` (Apache-2.0). A honeytoken
is a deliberately fake asset whose ONLY purpose is to be used by an attacker —
any use is a high-fidelity intrusion signal.

## 1. Token kinds and where each belongs

| Kind | Shape | Plant where |
|---|---|---|
| `opaque` | random 32-byte string | files, DNS TXT-ish records, config comments |
| `api-key` | provider-shaped key string | source repos, CI configs, docs, S3 buckets |
| `credential` | username + password pair | database dumps, config files, "leftover" notes |
| `beacon` | URL/hostname that logs hits | email signatures, PDFs, spreadsheets, DNS |

Placement rule: the token must be *reachable by an attacker but not used by
anyone legitimate*. A honeytoken in active use is noise, not detection.

## 2. Lifecycle — every state transition is explicit and audited

```
created → active → (rotated → active) → revoked → cleaned
```

- **created**: token generated (32 random bytes, base64url for output), metadata
  recorded (`label`, `kind`, `environment`, `generation`, timestamps). Not yet
  armed.
- **activate**: arming is a separate step, and it is AUTHORIZED — deployment is
  rejected unless the target environment is in the operator's authorized set.
  Only a freshly `created` token can be activated (no re-arming revoked tokens).
- **rotate**: revoke + create in one audited action; the replacement inherits
  the label/kind/environment and bumps `generation`. Rotation keeps the audit
  trail linked (`replaces:<old-id>`).
- **revoke**: state flips, the digest index drops the token, and the raw key
  material is zero-filled. Revocation is idempotent.
- **cleanup**: removes the token from the store entirely after revocation.
- Every action (`created | activated | rotated | revoked | cleaned | triggered |
  classified | replay-rejected`) lands in an append-only audit log with actor +
  timestamp.

## 3. Trigger verification — nonces, signatures, replay protection

When a honeytoken is used, the alert must itself be trustworthy:

- The trigger report carries the token, a nonce, the occurrence time, and an
  HMAC-SHA256 signature over `nonce:occurredAt` keyed by the token material.
- **Replay window:** a trigger older than 5 minutes (or with an empty nonce) is
  rejected outright — attackers replaying an intercepted alert must not be able
  to flood the channel.
- **Replay rejection is itself audited** (`replay-rejected`), so an attacker
  probing the alerting path is visible too.
- Triggers carry a nonce hash and source hash — never the raw source — so the
  alert channel does not leak where the token was planted.
- Classification is explicit: `pending | confirmed | dismissed`. An unconfirmed
  trigger is a lead, not an incident.

## 4. Environment authorization

- Tokens are deployed per named environment, and the set of authorized
  environments is fixed at manager construction.
- Deploying into a non-authorized environment throws — deception assets must
  never silently spread into production or third-party systems.
- Labels and environment names are validated (alphanumeric/underscore/dash,
  bounded length) before use.

## 5. Design rules that make honeytokens useful

- One alert sink per deployment, wired at construction; a honeytoken whose
  trigger goes nowhere is a liability (it arms you to nothing).
- The audit key must be ≥ 32 bytes — it signs the audit chain, so a weak key
  undermines the whole trail.
- Label tokens by PURPOSE, not by target ("prod-aws-key-canary", not "test1").
- Document every planted token's location in the case file — an untracked
  honeytoken is indistinguishable from a real leaked credential later.
- Defensive framing: honeytokens are for detecting unauthorized use of YOUR
  assets. Planting them in systems you are authorized to test is in-scope;
  planting them anywhere else is not.

## 6. OSA-specific wiring

- Generate material with `openssl rand -base64 32` `[LOCAL]`.
- Sign triggers with `openssl dgst -sha256 -hmac <key>` `[LOCAL]` or an HMAC in
  your tooling.
- Keep the audit log as append-only JSONL in the case directory.
- For repo canaries, consider GitHub's secret-scanning partner program:
  a fake AWS key with an alerting webhook fires when the secret scanner sees it.

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/deception/honeytokens.ts`), Apache-2.0. Patterns described; no code copied.

Part of the offensive skill library — see also `opsec-operational-discipline`
and `evidence-vault-chain-of-custody`.