---
name: systematic-debugging
description: Methodical bug investigation
triggers:
  - bug
  - error
  - fix
  - broken
  - not working
---

# Systematic Debugging Skill

## When This Activates
When investigating bugs or unexpected behavior.

## Process
1. **REPRODUCE** - Create consistent reproduction steps
2. **ISOLATE** - Find smallest reproduction case
3. **BISECT** - When did it start working/break?
4. **HYPOTHESIZE** - Form specific, testable theories
5. **TEST** - Validate hypotheses systematically
6. **FIX** - Implement minimal, targeted fix
7. **VERIFY** - Confirm fix resolves issue
8. **PREVENT** - Add regression test

## Output Format
```markdown
## Bug Analysis: [Issue]

### Reproduction
1. [Step 1]
2. [Step 2]
Expected: [X]
Actual: [Y]

### Investigation
- Hypothesis 1: [Theory] → Result: [Confirmed/Rejected]
- Hypothesis 2: [Theory] → Result: [Confirmed/Rejected]

### Root Cause
[What's wrong and why]

### Fix
[Code changes]

### Regression Test
[Test added to prevent recurrence]
```
