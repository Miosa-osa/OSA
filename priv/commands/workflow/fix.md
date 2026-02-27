---
name: fix
description: Apply fixes from a review or debug session
arguments:
  - name: target
    required: true
    description: "all | critical | high | issue-numbers (e.g., 1,2,3)"
---

# Fix - Apply Fixes

Apply fixes identified from code review, PR review, or debugging.

## Context

This command works with issues identified by:
- `/review` - Code review
- `/pr-review` - PR review
- `/debug` - Debug session

## Fix Strategies

### Fix All
Apply all identified fixes, starting with critical.
```
Order:
1. Critical (P0)
2. High (P1)
3. Medium (P2)
4. Low (P3)
```

### Fix by Severity
```
fix critical  → Only P0 issues
fix high      → P0 and P1 issues
fix medium    → P0, P1, and P2 issues
```

### Fix Specific
```
fix 1,3,5     → Fix issues #1, #3, #5
```

## Process

### Step 1: Load Issues
```
Retrieve issues from:
- Current session context
- TaskMaster tasks tagged with "fix"
- Last review report
```

### Step 2: Plan Fixes
```
For each issue:
1. Identify affected file(s)
2. Determine fix approach
3. Check for conflicts
4. Estimate impact
```

### Step 3: Apply Fixes (One at a Time)

```
For each fix:
1. Read current file state
2. Apply targeted change
3. Run tests
4. If tests pass → continue
5. If tests fail → revert, report, skip
```

### Step 4: Verify All Fixes

```bash
# Run full test suite
npm test  # or equivalent

# Run linter
npm run lint

# Check types
npm run type-check
```

### Step 5: Report Results

```
FIX REPORT
==========
Applied: 5/7 fixes
Failed: 2 fixes (reverted)

Applied Fixes:
--------------
[P0] #1 SQL injection in user.ts:45
     → Used parameterized query

[P0] #2 Missing auth check in api.ts:23
     → Added authentication middleware

[P1] #3 Null pointer in utils.ts:89
     → Added null check

[P1] #4 Race condition in worker.ts:156
     → Added mutex lock

[P2] #5 Duplicate code in helper.ts:34
     → Extracted to shared function

Failed Fixes (Reverted):
------------------------
[P2] #6 Rename variable in legacy.ts
     → Caused 3 test failures
     → Needs manual review

[P3] #7 Add type annotation
     → Conflicted with existing type
     → Skipped

Verification:
-------------
Tests: 47 passed, 0 failed
Lint: No errors
Types: No errors

Next Steps:
-----------
- Review failed fixes manually
- Run /review to verify no new issues
- Commit changes: /commit
```

## Safety Features

1. **One fix at a time** - Easier to identify which fix caused issues
2. **Test after each fix** - Catch problems immediately
3. **Auto-revert on failure** - Don't leave broken state
4. **Preserve original** - Can always recover

## Undo

If fixes cause problems:
```bash
# Revert all changes
git checkout -- .

# Or revert specific file
git checkout -- path/to/file.ts
```

## Agent Dispatch

Primary: @refactorer (for applying changes)
Support: @test-automator (verify each fix)
Support: @code-reviewer (validate approach)
