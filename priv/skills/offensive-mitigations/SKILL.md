---
name: offensive-mitigations
description: "Security mitigation reference and bypass catalog: ASLR, DEP/NX, RELRO, stack canaries, CFI, sandboxing, seccomp. Covers both detection of enabled mitigations and known bypass techniques. Use when assessing target hardening or planning exploit mitigation bypasses."
category: security
triggers:
  - "mitigations"
  - "offensive mitigations"
  - "exploit dev"
  - "exploit dev attack"
  - "exploit dev exploitation"
  - "mitigations methodology"
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

# SKILL: Modern Kernel Exploit Mitigations

## Metadata
- **Skill Name**: security-mitigations
- **Folder**: offensive-mitigations
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/mitigations.md

## Description
Security mitigation reference and bypass catalog: ASLR, DEP/NX, RELRO, stack canaries, CFI, sandboxing, seccomp. Covers both detection of enabled mitigations and known bypass techniques. Use when assessing target hardening or planning exploit mitigation bypasses.

## Trigger Phrases
Use this skill when the conversation involves any of:
`mitigations, ASLR bypass, DEP bypass, NX bypass, RELRO, stack canary bypass, CFI bypass, sandbox bypass, seccomp bypass, mitigation detection, checksec`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Bypass Techniques](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Shadow Call Stack (SCS)](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [Practitioner](references/methodology-04.md) — part 4; consult for this stage and its examples.
