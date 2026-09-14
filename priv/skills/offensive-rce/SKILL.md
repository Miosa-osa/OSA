---
name: offensive-rce
description: "Remote Code Execution testing checklist: OS command injection, SSTI-to-RCE, deserialization RCE, file upload RCE, XXE with SSRF to RCE, RCE via dependency confusion, and CVE-based RCE patterns. Use for web app pentests and bug bounty RCE discovery."
category: security
triggers:
  - "rce"
  - "offensive rce"
  - "web"
  - "web attack"
  - "web exploitation"
  - "rce methodology"
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

# SKILL: Remote Code Execution

## Metadata
- **Skill Name**: rce
- **Folder**: offensive-rce
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/rce.md

## Description
Remote Code Execution testing checklist: OS command injection, SSTI-to-RCE, deserialization RCE, file upload RCE, XXE with SSRF to RCE, RCE via dependency confusion, and CVE-based RCE patterns. Use for web app pentests and bug bounty RCE discovery.

## Trigger Phrases
Use this skill when the conversation involves any of:
`RCE, remote code execution, command injection, OS injection, SSTI RCE, deserialization RCE, file upload RCE, XXE RCE, dependency confusion, code execution`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Server-Side Template Injection (SSTI) Payloads](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Bypass Techniques](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [Prototype Pollution → RCE (Node.js)](references/methodology-04.md) — part 4; consult for this stage and its examples.
- [Tool status note](references/methodology-05.md) — part 5; consult for this stage and its examples.
