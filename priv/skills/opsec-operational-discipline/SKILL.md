---
name: opsec-operational-discipline
description: "Operational security for offensive engagements: OPSEC level tiers (silent/covert/loud) with detection-event budgets, cooldown and jitter mechanics, traffic blending, log sanitization, IOC tracking, abort-recommendation logic, and cleanup-on-completion. Use when planning how noisy an engagement should be, tuning scan/exploit pacing to avoid detection, responding to detection events during an engagement, or sanitizing logs and reports before delivery. Derived from the T3MP3ST platform's OPSEC controller (Apache-2.0)."
category: security
triggers:
  - "opsec"
  - "operational security"
  - "detection avoidance"
  - "scan pacing"
  - "noise reduction"
  - "log sanitization"
  - "engagement stealth"
tools:
  - file_read
  - file_write
  - file_edit
  - shell_execute
  - web_search
---

# OPSEC — Operational Discipline

Derived from T3MP3ST's `src/opsec/index.ts` (Apache-2.0). OPSEC is a
configuration, not a vibe: pick a level, budget your detections, and act on the
signals.

## 1. The three OPSEC levels

| Level | max detection events | cooldown after detection | jitter range | traffic blending | log sanitization | cleanup on complete |
|---|---|---|---|---|---|---|
| `silent` | 1 | 300 000 ms (5 min) | 5 000–15 000 ms | yes | yes | yes |
| `covert` (default) | 3 | 60 000 ms (1 min) | 1 000–5 000 ms | yes | yes | yes |
| `loud` | 20 | 2 000 ms | 100–500 ms | no | no | no |

- **silent**: CTF/lab work or engagements where a single detection ends the
  mission. One detection event → long cooldown.
- **covert**: the default for authorized engagements. Small jitter between
  actions, blending on, three detections before reconsideration.
- **loud**: only for engagements where the operator has explicitly accepted
  detection (purple-team exercises, detection-validation runs). No blending, no
  sanitization, cleanup off — the point is to be seen.

## 2. Detection events and the abort recommendation

- Every detection (IDS alert, WAF block, honeypot hit, unexpected 403 shift) is
  an event with a severity, recorded with an IOC when known
  (`ip | domain | hash | signature | behavior`).
- Crossing the level's `maxDetectionEvents` budget triggers an
  **abort-recommended** signal with the reason attached. The recommendation is
  advisory to the operator but MANDATORY to surface — never swallow it.
- After any detection, the cooldown timer starts: no further actions until it
  expires. Cooldowns are per the level table, not per operator impatience.

## 3. Pacing mechanics that actually reduce detection

- **Jitter:** randomize inter-action delay within the level's jitter range —
  fixed intervals are the single most-detectable pattern in automated tooling.
- **Traffic blending:** make action traffic resemble legitimate traffic for the
  target (correct user-agents, realistic header sets, session reuse, business-
  hours timing where relevant).
- **Rate shaping:** scan in batches with pauses; prefer passive recon first
  (`offensive-osint`) and touch the target only when needed.
- **Log sanitization:** strip operator-identifying metadata (hostnames, user
  names, internal paths) from anything that leaves your machine. On `silent`/
  `covert` this is automatic; on `loud` it is deliberately off.

## 4. Cleanup on completion

- `cleanupOnComplete: true` (silent/covert) means the engagement ends clean:
  temp files removed, dropped artifacts accounted for, shells closed, tokens
  revoked. Track what you created so cleanup is a checklist, not an archaeology.
- `loud` runs skip cleanup by design — detection-validation exercises often want
  the artifacts for the blue team.
- Cleanup failures are findings: report anything you could not remove.

## 5. IOC tracking during the engagement

- Record every IOC you OBSERVE (defender responses, unexpected services) and
  every IOC you CREATE (your scanning IPs, user-agents, payload signatures).
- Your own IOCs feed the post-engagement report ("what the defender should have
  seen") — this is the purple-team payoff of good OPSEC discipline.

## 6. OSA-specific wiring

- Implement jitter in bash with `sleep $((RANDOM % range + min))` `[LOCAL]`.
- Rate-shape `nmap`/`ffuf`/`nuclei` with their built-in timing flags
  (`-T2`, `-rate-limit`, `-delay`) rather than custom loops.
- Sanitize reports before delivery: grep for operator hostname, usernames, and
  absolute paths; replace with role names.
- Pair with `honeytokens-deception` (their detection is your signal) and
  `penetration-testing` (scope discipline: OPSEC never justifies out-of-scope
  actions).

## Attribution

Derived from [elder-plinius/T3MP3ST](https://github.com/elder-plinius/T3MP3ST)
(`src/opsec/index.ts`, `src/types/index.ts` OpsecConfig/OpsecLevel), Apache-2.0.
Patterns described; no code copied.

Part of the offensive skill library — see also `penetration-testing` and
`redteam-multi-agent-orchestration`.