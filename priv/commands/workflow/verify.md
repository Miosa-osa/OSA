---
name: verify
description: Run verification checklist before claiming completion
---

# Verify - Completion Checklist

Ensure all quality gates pass before claiming work is complete.

## Golden Rule

**Never say "done" without verification evidence.**

## Verification Checklist

### 1. Code Compiles/Builds
```bash
# TypeScript/JavaScript
npm run build
npm run type-check

# Go
go build ./...

# Verify: No errors
```
**Evidence Required**: Build output showing success

### 2. Tests Pass
```bash
# Run test suite
npm test
go test ./...

# Verify: All tests pass
```
**Evidence Required**: Test output with pass count

### 3. New Tests Added (if new functionality)
```
For new features:
- Unit tests for new functions
- Integration tests if applicable
- Edge case tests
```
**Evidence Required**: Test file names and descriptions

### 4. Linting Passes
```bash
npm run lint
golangci-lint run
```
**Evidence Required**: Linter output showing no errors

### 5. No Regressions
```
Verify:
- Existing functionality still works
- No new warnings
- Performance not degraded
```
**Evidence Required**: Comparison or statement of verification

### 6. Edge Cases Handled
```
Document:
- What edge cases were considered
- How each is handled
- Any intentionally unhandled cases
```
**Evidence Required**: List of edge cases

### 7. Error Cases Handled
```
Document:
- What errors can occur
- How each is caught/handled
- User-facing error messages
```
**Evidence Required**: List of error scenarios

### 8. Security Checked (if applicable)
```
For security-sensitive changes:
- Input validation present
- No injection vulnerabilities
- Auth/authz correct
```
**Evidence Required**: Security review notes

### 9. Documentation Updated (if needed)
```
Check:
- Code comments accurate
- README updated
- API docs updated
```
**Evidence Required**: List of doc changes

### 10. Code Reviewed
```
Either:
- Self-review completed
- @code-reviewer review passed
```
**Evidence Required**: Review status

## Output Format

```
VERIFICATION CHECKLIST
======================
Task: [description]

Build:
------
[OK] npm run build - Success
[OK] npm run type-check - No errors
Command output: "Build completed in 3.2s"

Tests:
------
[OK] npm test - 47/47 passing
[OK] New tests added:
     - validateUser.test.ts (3 tests)
     - authMiddleware.test.ts (5 tests)
Command output: "47 tests passed"

Lint:
-----
[OK] npm run lint - No errors

Regressions:
-----------
[OK] All existing tests pass
[OK] No new warnings introduced

Edge Cases:
-----------
[OK] Handled:
     - Empty input → Returns error
     - Invalid format → Returns validation error
     - Duplicate entry → Returns conflict error

Error Handling:
--------------
[OK] Handled:
     - Network timeout → Retry with backoff
     - Auth failure → 401 response
     - Database error → 500 with logging

Security:
---------
[OK] Input validated
[OK] No SQL injection
[OK] Auth required on endpoint

Documentation:
--------------
[OK] JSDoc added to new functions
[OK] README updated with new feature

Code Review:
-----------
[OK] Self-review completed
[OK] No critical issues found

VERIFICATION RESULT: PASSED
---------------------------
All checks passed. Ready for commit/merge.
```

## Failure Handling

If any check fails:
```
VERIFICATION RESULT: FAILED
---------------------------
Failed checks:
[FAIL] Tests - 2 tests failing
       - validateUser.test.ts:45 - AssertionError
       - authMiddleware.test.ts:23 - Timeout

Action Required:
- Fix failing tests before claiming complete
- Re-run verification after fixes
```

## Quick Verify

For minor changes, use minimal checklist:
```
/verify --quick

Checks only:
- Build passes
- Tests pass
- Lint passes
```

## Agent Dispatch

Primary: @test-automator (run tests)
Support: @code-reviewer (review result)
