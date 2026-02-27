---
name: pr-review
description: Comprehensive PR review with issue identification and auto-fix
trigger: pr_review_request
agents: [code-reviewer, security-auditor, test-automator]
---

## PR Review Process

### Step 1: Gather Changes
```
Get diff from:
- GitHub PR URL
- Git branch comparison
- Staged changes (git diff --staged)
- Unstaged changes (git diff)
```

### Step 2: Multi-Agent Review

**@code-reviewer checks:**
- Code quality and readability
- Design patterns and architecture
- Error handling
- Edge cases
- Code duplication
- Naming conventions
- Comment quality

**@security-auditor checks:**
- Input validation
- SQL injection risks
- XSS vulnerabilities
- Authentication issues
- Authorization checks
- Sensitive data exposure
- Dependency vulnerabilities

**@test-automator checks:**
- Test coverage for changes
- Missing test cases
- Test quality
- Edge case coverage

### Step 3: Categorize Issues

```
CRITICAL (P0) - Must fix before merge
   - Security vulnerabilities
   - Data loss risks
   - Breaking changes
   - Crashes/exceptions

HIGH (P1) - Should fix before merge
   - Bugs that affect functionality
   - Performance issues
   - Missing error handling
   - Missing validation

MEDIUM (P2) - Consider fixing
   - Code smell
   - Minor bugs
   - Inconsistent patterns
   - Missing tests

LOW (P3) - Suggestions
   - Style improvements
   - Refactoring opportunities
   - Documentation improvements
   - Nice-to-haves
```

### Step 4: Create Tasks
For each issue:
1. Create TaskMaster task
2. Set priority based on severity
3. Link to specific file:line
4. Include fix suggestion

### Step 5: Offer Auto-Fix
Present options:
- Fix all issues
- Fix by severity
- Fix specific issues
- Explain issues first
