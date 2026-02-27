---
name: refactor
description: Safe code refactoring without behavior change
arguments:
  - name: target
    required: true
    description: File, function, or component to refactor
  - name: type
    required: false
    description: "extract | rename | simplify | restructure | optimize"
---

# Safe Refactoring Workflow

Improve code structure without changing behavior.

## Golden Rules

1. **Tests must pass before AND after**
2. **One change at a time**
3. **Commit after each successful step**
4. **If tests fail, revert immediately**

## Pre-Refactor Checklist

- [ ] Tests exist for the code
- [ ] All tests pass
- [ ] Code is in version control
- [ ] Understand what the code does
- [ ] Have a clear goal for the refactor

## Refactoring Types

### Extract
Pull code into a new function/component/module.
```
When to use:
- Function is too long (>30 lines)
- Repeated code blocks
- Nested logic too deep
- Single function doing multiple things
```

### Rename
Improve naming for clarity.
```
When to use:
- Name doesn't describe purpose
- Abbreviations are unclear
- Names have become inaccurate
- Inconsistent naming patterns
```

### Simplify
Reduce complexity.
```
Techniques:
- Remove dead code
- Flatten nested conditionals
- Replace conditionals with polymorphism
- Use early returns
- Eliminate temporary variables
```

### Restructure
Reorganize code architecture.
```
When to use:
- Poor separation of concerns
- Circular dependencies
- God classes/functions
- Misplaced responsibilities
```

### Optimize
Improve performance (only after profiling).
```
When to use:
- Profiler shows bottleneck
- Measured performance issue
- NOT based on assumption
```

## Step-by-Step Process

### Step 1: Verify Baseline
```bash
# Run tests
npm test  # or equivalent

# Verify all pass
# DO NOT proceed if tests fail
```

### Step 2: Plan Changes
```
Document:
- What will change
- What should NOT change
- Expected behavior after
- Rollback plan
```

### Step 3: Make ONE Change
```
Examples of atomic changes:
- Rename one variable
- Extract one function
- Inline one call
- Remove one piece of dead code
```

### Step 4: Run Tests
```bash
npm test
```

### Step 5: If Tests Pass → Commit
```bash
git add -p  # Stage only refactor changes
git commit -m "refactor: [description]"
```

### Step 6: If Tests Fail → Revert
```bash
git checkout -- .
# Analyze why it failed
# Try smaller change
```

### Step 7: Repeat Steps 3-6

## Output Format

```
REFACTORING REPORT
==================
Target: [what was refactored]
Type: [extract | rename | simplify | etc.]
Status: [COMPLETE | PARTIAL | ROLLED BACK]

Changes Made:
-------------
1. Extracted validateUser() from handleLogin()
   - Moved lines 45-67 to new function
   - Added proper typing

2. Renamed 'data' to 'userProfile'
   - 12 occurrences updated

3. Simplified nested conditionals
   - Reduced cyclomatic complexity from 8 to 3

Tests:
------
Before: 47 passing
After: 47 passing
No behavior change confirmed

Files Modified:
--------------
- src/auth/login.ts
- src/auth/validation.ts (new)
```

## Agent Dispatch

Primary: @refactorer
Support: @test-automator (verify tests)
Support: @code-reviewer (review result)
