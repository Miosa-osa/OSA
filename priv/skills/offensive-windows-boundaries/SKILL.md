---
name: offensive-windows-boundaries
description: "Windows security boundary taxonomy and attack surface enumeration: kernel/user boundary, sandbox boundaries (LPAC, AppContainer), COM/RPC boundaries, hypervisor boundary, trust level transitions. Use when planning privilege escalation paths, sandbox escapes, or understanding Windows security architecture."
category: security
triggers:
  - "windows boundaries"
  - "offensive windows boundaries"
  - "infrastructure"
  - "infrastructure attack"
  - "infrastructure exploitation"
  - "windows boundaries methodology"
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

# SKILL: Week 7: Defeating Windows Security Boundaries

## Metadata
- **Skill Name**: windows-boundaries
- **Folder**: offensive-windows-boundaries
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/7-windows-boundaries.md

## Description
Windows security boundary taxonomy and attack surface enumeration: kernel/user boundary, sandbox boundaries (LPAC, AppContainer), COM/RPC boundaries, hypervisor boundary, trust level transitions. Use when planning privilege escalation paths, sandbox escapes, or understanding Windows security architecture.

## Trigger Phrases
Use this skill when the conversation involves any of:
`Windows boundaries, security boundary, kernel user boundary, sandbox escape, AppContainer, LPAC, COM boundary, RPC boundary, hypervisor, Hyper-V, privilege escalation, trust level`


## Full Methodology

# Week 7: Defeating Windows Security Boundaries

## Overview

_created by AnotherOne from @Pwn3rzs Telegram channel_.

Week 6 taught you how mitigations work defensively.
You'll learn to bypass the OS security _policies and features_ that prevent your code from running, your processes from accessing protected resources, and your actions from being logged.
This is distinct from Week 8, which teaches you how to bypass _exploit mitigations_ (DEP, ASLR, CFG) once your code is already running.

> **Week 7 vs Week 8 - The Key Distinction**:
>
> - **Week 7** answers: _"Can my code execute at all?"_ - bypass AMSI, WDAC, ASR, AppContainers, integrity levels, PPL, ETW telemetry
> - **Week 8** answers: _"Can my exploit succeed?"_ - bypass DEP, ASLR, stack cookies, CFG/XFG, heap safe-unlinking

**This Week's Focus**:

- Offensive reconnaissance and mitigation fingerprinting
- AMSI bypass and script-based attack techniques
- Protected Process Light (PPL) exploitation
- Sandbox, integrity level, and AppContainer bypass
- WDAC and Attack Surface Reduction (ASR) bypass
- ETW manipulation and telemetry blinding
- Kernel driver interaction fundamentals (preparation for Week 11)

**Prerequisites**:

- Completed Week 6: Understanding Modern Windows Mitigations
- Week 5: Basic exploitation techniques (stack overflow, ROP, heap)
- Familiarity with WinDbg, x64dbg, and IDA/Ghidra
- C/C++, Python, and assembly knowledge

### Week 7 Deliverables

By the end of this week, you should have completed:

- [ ] **Recon Tool**: Built a mitigation fingerprinting tool
- [ ] **AMSI Bypass**: Implemented working AMSI bypass techniques
- [ ] **PPL Research**: Documented PPL bypass vectors
- [ ] **Sandbox Escape**: Bypassed AppContainer or integrity level restrictions
- [ ] **WDAC/ASR Bypass**: Demonstrated at least one WDAC and one ASR bypass
- [ ] **ETW Blinding**: Implemented ETW provider patching to suppress telemetry
- [ ] **Driver IOCTL Lab**: Loaded a test driver, sent an IOCTL, set a kernel breakpoint (Week 11 prep)



---

## Extended reference

This skill's full detail is split: read `references/detail.md` with file_read when you need the deep payload tables, tool matrices, or per-technique checklists that did not fit the skill body.
