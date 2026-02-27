---
globs: ["**/*"]
description: "How to approach code reviews. EDIT THIS FILE to add your insights."
---

# Code Review Behavior Guide

**HUMAN EDIT SECTION** - Add your code review insights below the line.

## Default Code Review Protocol

### Correctness
- [ ] Logic is correct
- [ ] Edge cases handled
- [ ] Error handling present
- [ ] No obvious bugs

### Security
- [ ] No hardcoded secrets
- [ ] Input validation present
- [ ] SQL injection prevention
- [ ] XSS prevention
- [ ] Proper auth checks

### Performance
- [ ] No N+1 queries
- [ ] Efficient algorithms
- [ ] Proper caching
- [ ] No memory leaks

### Maintainability
- [ ] Clear naming
- [ ] Appropriate comments
- [ ] Small functions
- [ ] Single responsibility
- [ ] DRY (but not over-abstracted)

### Testing
- [ ] Tests included
- [ ] Edge cases tested
- [ ] Mocks appropriate
- [ ] Good coverage

### Style
- [ ] Follows conventions
- [ ] Consistent formatting
- [ ] No dead code
- [ ] Imports organized

## Review Output Format
```
## Code Review Summary

### Overall: [APPROVED | NEEDS CHANGES | BLOCKED]

### Issues Found
1. [CRITICAL] file:line - description
2. [MAJOR] file:line - description
3. [MINOR] file:line - description

### Suggestions
- Suggestion 1
- Suggestion 2

### Positive Notes
- What was done well
```

---

## YOUR INSIGHTS (Edit Below)

<!--
Add your own code review insights here. Examples:

### Our Review Standards
- All PRs need 2 approvals
- Security-sensitive code needs security team review
- Database changes need DBA review

### Common Issues We Flag
- Missing error boundaries in React
- Unbounded queries without pagination
- Console.log left in code

### Auto-Approve Criteria
- Documentation-only changes
- Dependency updates (with passing tests)
- Typo fixes
-->

### Our Review Requirements
<!-- Add your review requirements -->

### Common Issues to Flag
<!-- Add patterns to catch -->

### What We Auto-Approve
<!-- What doesn't need full review -->

### Review SLA
<!-- Expected turnaround time -->

### Escalation Process
<!-- When to escalate reviews -->
