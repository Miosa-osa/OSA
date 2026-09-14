---
name: offensive-fuzzing-course
description: "Week 2 of the exploit development curriculum. Covers fuzzing methodology: target selection, corpus generation, coverage-guided fuzzing with AFL++/libFuzzer, structured fuzzing, and triage/deduplication. Use when setting up fuzz campaigns, selecting harness strategies, or triaging fuzzer output."
category: security
triggers:
  - "fuzzing course"
  - "offensive fuzzing course"
  - "fuzzing"
  - "fuzzing attack"
  - "fuzzing exploitation"
  - "fuzzing course methodology"
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

# SKILL: Week 2: Finding Vulnerabilities Through Fuzzing

## Metadata
- **Skill Name**: fuzzing-course
- **Folder**: offensive-fuzzing-course
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/2-fuzzing.md

## Description
Week 2 of the exploit development curriculum. Covers fuzzing methodology: target selection, corpus generation, coverage-guided fuzzing with AFL++/libFuzzer, structured fuzzing, and triage/deduplication. Use when setting up fuzz campaigns, selecting harness strategies, or triaging fuzzer output.

## Trigger Phrases
Use this skill when the conversation involves any of:
`fuzzing curriculum, AFL++, libFuzzer, coverage-guided fuzzing, corpus generation, harness, fuzz target, mutation, triage, crash dedup, week 2, exploit dev course`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Day 2: Continue Fuzzing with `AFL++`](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Lab 1: Set up FuzzTest and run a basic property](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [Real-World Impact: Honggfuzz Finding TLS Vulnerabilities](references/methodology-04.md) — part 4; consult for this stage and its examples.
