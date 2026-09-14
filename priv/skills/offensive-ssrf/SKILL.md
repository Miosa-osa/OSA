---
name: offensive-ssrf
description: "Server-Side Request Forgery testing checklist: SSRF discovery, blind SSRF with out-of-band, cloud metadata endpoints (AWS/GCP/Azure), SSRF filter bypass techniques (IP encoding, DNS rebinding, redirect chains), and SSRF to RCE escalation. Use for web app SSRF testing and bug bounty."
category: security
triggers:
  - "ssrf"
  - "offensive ssrf"
  - "web"
  - "web attack"
  - "web exploitation"
  - "ssrf methodology"
tools:
  - file_read
  - file_glob
  - file_grep
  - file_write
  - file_edit
  - dir_list
  - shell_execute
  - web_fetch
  - web_search
  - delegate
---

# SKILL: Server-Side Request Forgery (SSRF)

## Metadata
- **Skill Name**: ssrf
- **Folder**: offensive-ssrf
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/ssrf.md

## Description
Server-Side Request Forgery testing checklist: SSRF discovery, blind SSRF with out-of-band, cloud metadata endpoints (AWS/GCP/Azure), SSRF filter bypass techniques (IP encoding, DNS rebinding, redirect chains), and SSRF to RCE escalation. Use for web app SSRF testing and bug bounty.

## Trigger Phrases
Use this skill when the conversation involves any of:
`SSRF, server-side request forgery, blind SSRF, cloud metadata, AWS metadata, GCP metadata, SSRF bypass, DNS rebinding, redirect chain, SSRF RCE, internal port scan`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [PDF SSRF Exploitation](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Bypass Testing](references/methodology-03.md) — part 3; consult for this stage and its examples.
