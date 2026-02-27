---
name: pr:review
description: Review a PR, identify issues, and optionally fix them
arguments:
  - name: source
    description: PR URL, branch name, or "staged" for staged changes
    required: false
---

## PR Review Workflow

### What This Does
1. Fetches the PR/diff
2. Reviews with @code-reviewer + @security-auditor
3. Identifies issues by severity
4. Creates TaskMaster tasks for each issue
5. Optionally auto-fixes issues

### Output Format

```
┌─────────────────────────────────────────────────────────────────┐
│ PR REVIEW: [PR Title/Branch]                                    │
├─────────────────────────────────────────────────────────────────┤
│ Files Changed: X                                                │
│ Lines: +XXX / -XXX                                              │
├─────────────────────────────────────────────────────────────────┤
│ CRITICAL ISSUES (Must Fix)                                      │
│   1. [Issue] - [File:Line]                                      │
│   2. [Issue] - [File:Line]                                      │
├─────────────────────────────────────────────────────────────────┤
│ HIGH ISSUES (Should Fix)                                        │
│   3. [Issue] - [File:Line]                                      │
├─────────────────────────────────────────────────────────────────┤
│ MEDIUM ISSUES (Consider)                                        │
│   4. [Issue] - [File:Line]                                      │
├─────────────────────────────────────────────────────────────────┤
│ SUGGESTIONS (Optional)                                          │
│   5. [Suggestion] - [File:Line]                                 │
├─────────────────────────────────────────────────────────────────┤
│ WHAT'S GOOD                                                     │
│   - [Positive observation]                                      │
└─────────────────────────────────────────────────────────────────┘

Tasks Created:
  - TASK-001: Fix [Critical Issue 1]
  - TASK-002: Fix [Critical Issue 2]
  - TASK-003: Fix [High Issue 3]

Reply with:
  "fix all"      - Auto-fix all issues
  "fix critical" - Auto-fix critical only
  "fix 1,2,3"    - Fix specific issues
  "explain 2"    - Explain issue #2 in detail
```
