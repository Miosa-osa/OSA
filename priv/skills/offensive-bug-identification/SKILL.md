---
name: offensive-bug-identification
description: "Systematic bug identification methodology: source code review patterns, black-box testing strategies, taint analysis, dangerous function hunting, data flow tracing, and automated scanning setup. Use for code audits, bug bounty triage, or building vulnerability identification pipelines."
category: security
triggers:
  - "bug identification"
  - "offensive bug identification"
  - "fuzzing"
  - "fuzzing attack"
  - "fuzzing exploitation"
  - "bug identification methodology"
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

# SKILL: Bug Identification

## Metadata
- **Skill Name**: bug-identification
- **Folder**: offensive-bug-identification
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/bug-identification.md

## Description
Systematic bug identification methodology: source code review patterns, black-box testing strategies, taint analysis, dangerous function hunting, data flow tracing, and automated scanning setup. Use for code audits, bug bounty triage, or building vulnerability identification pipelines.

## Trigger Phrases
Use this skill when the conversation involves any of:
`bug identification, code review, taint analysis, dangerous functions, data flow, source audit, black box, vulnerability identification, static analysis, code audit, bug hunting`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Supply Chain Attack Surface](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Windows 11 Patch Diffing](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [IDA Pro and Rust Tools for Vulnerability Research](references/methodology-04.md) — part 4; consult for this stage and its examples.
