---
name: review
description: Trigger code review on recent changes
arguments:
  - name: target
    required: false
    description: "staged | unstaged | branch:name | file:path | pr:number"
---

# Code Review Workflow

Comprehensive code review with multi-dimensional analysis.

## Scope Detection

1. **Auto-detect target**:
   - If staged changes: Review staged
   - If on feature branch: Review branch vs main
   - If PR number given: Review PR
   - If file path given: Review specific file

2. **Get diff**:
   ```bash
   # Staged
   git diff --staged

   # Branch
   git diff main...HEAD

   # PR
   gh pr diff [number]
   ```

## Review Dimensions

### 1. Correctness
- [ ] Logic is correct
- [ ] Edge cases handled
- [ ] Error states handled
- [ ] No obvious bugs
- [ ] Business requirements met

### 2. Security
- [ ] No hardcoded secrets
- [ ] Input validation present
- [ ] SQL injection prevented
- [ ] XSS prevented
- [ ] Auth/authz checks correct
- [ ] No sensitive data logged

### 3. Performance
- [ ] No N+1 queries
- [ ] Efficient algorithms (O(n) vs O(n^2))
- [ ] Proper caching
- [ ] No memory leaks
- [ ] Async where appropriate

### 4. Maintainability
- [ ] Clear naming
- [ ] Single responsibility
- [ ] DRY (but not over-abstracted)
- [ ] Appropriate comments
- [ ] Easy to test

### 5. Testing
- [ ] Tests included for new code
- [ ] Edge cases tested
- [ ] Mocks appropriate
- [ ] Good coverage

### 6. Style
- [ ] Follows project conventions
- [ ] Consistent formatting
- [ ] No dead code
- [ ] Imports organized

## Issue Severity

```
CRITICAL (P0) - Block merge
  Security vulnerabilities, data loss, crashes

HIGH (P1) - Should fix
  Bugs, missing validation, performance issues

MEDIUM (P2) - Consider fixing
  Code smell, missing tests, inconsistency

LOW (P3) - Nice to have
  Style, documentation, minor improvements
```

## Output Format

```
CODE REVIEW REPORT
==================
Target: [what was reviewed]
Verdict: [APPROVED | NEEDS CHANGES | BLOCKED]

Summary:
[1-2 sentence overview]

Issues Found:
-------------
[P0] file.ts:45 - SQL injection risk
     Fix: Use parameterized query

[P1] api.ts:23 - Missing error handling
     Fix: Add try-catch with proper error response

[P2] utils.ts:89 - Could be simplified
     Suggestion: Use Array.map instead of forEach

Positive Notes:
--------------
- Good use of TypeScript strict mode
- Clean separation of concerns
- Excellent test coverage

Suggestions:
-----------
- Consider adding JSDoc for public functions
- Could extract common logic to shared utility
```

## Agent Dispatch

Primary: @code-reviewer
Support: @security-auditor (if security-sensitive)
Support: @performance-optimizer (if performance-critical)
