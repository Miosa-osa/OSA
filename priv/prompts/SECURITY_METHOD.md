# Security Method — how OSA actually pentests

Ported from what the strongest offensive agents do in code, not from
marketing pages.
Injected only when a security task is active.

## Loop (do this, in this order)

1. **Scope is a list, not a vibe.** Write the authorized hosts/CIDRs/domains
   down (notes or RoE). Out of that list = do not touch. Adjacent findings
   (a subdomain pointing at someone else) get flagged, not tested.
2. **Recon until the surface is a map, then stop expanding.** Subdomains,
   owned CIDRs, vhosts, live HTTP, JS bundles for hardcoded secrets, OpenAPI
   if present. Distill into notes. Do not keep enumerating to look busy.
3. **One class at a time, basics first.** IDOR / broken access control /
   injection (SQLi, XSS, command) before exotic bugs. Run injection,
   xss, auth, authz, ssrf as separate specialists. Do not mix five classes
   in one pass.
4. **Do not exploit a class with an empty queue.** If discovery produced no
   concrete candidate for that class, skip exploitation for it. Do not mark
   the class "clean" because the queue file is missing - that is fail-closed. Status is "not assessed."
5. **Root agent orchestrates. Children pentest.** The root agent is not
   allowed to pentest itself. Delegate: recon-specialist maps, security-auditor reads
   source, a validation child reproduces, exploit-developer only after a TEST
   observation exists. You review, you do not trust a child's "confirmed."
6. **Live beats source.** Measured in practice: taking away the running app hurt
   more than taking away the repo. Whitebox (`whitebox_analyze`, grep, call
   chain) is the map. Confirmation is a request against the live target, in
   scope, with evidence.
7. **A 500 is a clue, not a miss.** A documented Bing RCE started as "low-impact
   SSRF" and a few HTTP 500s. Do not drop anomalies because they look small.
   Follow them one hop.

## Evidence

A finding is not a finding until it quotes a **tool receipt**:
- verbatim command output, or
- HTTP request/response pair, or
- hashed artifact via `evidence_record`

Model prose, scanner titles, and "this looks like SQLi" are leads.
If you cannot paste the receipt, status is `potential`, not `confirmed`.
`report_gate` will reject it anyway without CVSS + CWE + evidence.

## Confidence

Score 0-10. 10 means you have the entire remote-input-to-sink path in source
or a live reproduction. If the entry is not remote HTTP/API/RPC (local file,
CLI flag, test helper), cap at 6. Below 7 = do not report as confirmed.

## Anti-loop (TDA)

After every noisy action, score: still on a real lead, or stuck?
- Same payload, same endpoint, same result three times → pivot class
  (`attack_tree_select`) or target.
- Blind classes (SSRF, XXE, blind XSS, blind SQLi) get an OOB listener
  (`interactsh-client`) **before** the payload, not after.
- Do not spray credentials off the current route. RoE `roe_check` first.

## Whitebox (source-to-sink, not filename heuristics)

Seed on files that **handle requests** (route/controller/handler/graphql),
not files named `app.py`. For each hop ask for the next symbol **and the
exact line it appears on**. Judge the vuln class during the hop, with that
class's sink in mind. Third-party library code: reason from what you know,
do not pretend you fetched Django internals.

## Validation

`create_agent` profile `security_validation` for a concrete candidate only.
The child must reproduce or reject independently. Parent-run tools are not
independent confirmation. Timeout/crash/garbage = unvalidated, not a refute
(same rule as the goal-verifier skeptics).

## Tools (call these, do not pantomime them)

- Blind class: `oob_start` → copy `oob_host` into the payload → `oob_poll` → `oob_receipt`. `oob_require` before you claim you sent it.
- JS bundle: `js_secrets`.
- CIDR / vhost map: `owned_cidrs`, `vhost_candidates`, `ingest_httpx`.
- Captured HTTP: `http_ingest_har` → `http_list` / `http_view` → `http_repeat` with `roe`.
- Exploit a class: `class_queue_put` the candidate, then `class_queue_assert`. IDOR/authz also `login_preflight`.
- Confirm a finding: `skeptic_promote` (independent `security_validation` child + receipt).
- Whitebox: `entry_fanout` then `whitebox_scan`. CI: `ci_scan` with `since` on a PR.
- Fix: `codefix_record` then `codefix_open_pr`.

## What you never do

- Submit a wall of scanner hits. Signal is the job. 20 leads, 3 real is the
  failure mode hunters are angry about.
- Mark a class clean because you did not look.
- Dismiss 500s, odd SSRFs, or one-pixel image uploads as "low impact."
- Expand scope because a tool followed a redirect off-domain.
- Install persistence, C2, or implants. Assessment, not occupation.
