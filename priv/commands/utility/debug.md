---
name: debug
description: Start systematic debugging process
arguments:
  - name: issue
    required: true
    description: Description of the bug or error
---

# Systematic Debugging Workflow

Follow the 8-step systematic debugging process to find and fix bugs.

## Step 1: REPRODUCE

**Goal**: Confirm the bug exists and understand its behavior.

```
Questions to answer:
- Can I reproduce it consistently?
- What are the exact steps?
- What is expected vs actual behavior?
- Does it happen in all environments?
```

## Step 2: ISOLATE

**Goal**: Narrow down the scope.

```
Techniques:
- Binary search through code/commits
- Disable features until bug disappears
- Simplify input until minimal reproduction
- Check if bug exists in other branches
```

## Step 3: IDENTIFY

**Goal**: Find the exact location.

```
Tools:
- Add strategic console.log/print statements
- Use debugger breakpoints
- Check error stack traces
- Review recent changes (git log, git blame)
```

## Step 4: HYPOTHESIZE

**Goal**: Form theories about the cause.

```
Common causes:
- Race condition
- Null/undefined value
- Off-by-one error
- State mutation
- Missing error handling
- Incorrect assumption
```

## Step 5: TEST HYPOTHESIS

**Goal**: Prove or disprove each theory.

```
For each hypothesis:
1. Predict what you'll see if true
2. Add instrumentation
3. Run and observe
4. Mark as confirmed or ruled out
```

## Step 6: FIX

**Goal**: Implement the correct fix.

```
Guidelines:
- Fix the root cause, not symptoms
- Keep fix minimal and focused
- Don't introduce new bugs
- Consider edge cases
```

## Step 7: VERIFY

**Goal**: Confirm the fix works.

```
Verification:
- Original reproduction case passes
- No regression in related functionality
- All existing tests pass
- Manual testing confirms fix
```

## Step 8: PREVENT

**Goal**: Prevent recurrence.

```
Actions:
- Add regression test
- Update documentation if needed
- Consider if similar bugs exist elsewhere
- Add validation/guards if appropriate
```

## Output Format

```
DEBUG REPORT
============
Issue: [description]
Status: [INVESTIGATING | FOUND | FIXED]

Root Cause:
[What was actually wrong]

Fix Applied:
[What was changed and why]

Files Modified:
- path/to/file.ts:45 - [change description]

Regression Test:
- [test name] - Tests the specific fix

Prevention:
- [Any additional measures taken]
```

## Agent Dispatch

Primary: @debugger
Support: @code-reviewer (for fix review)
