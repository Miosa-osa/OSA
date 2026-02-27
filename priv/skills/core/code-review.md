---
name: code-review
description: Thorough code review checklist
triggers:
  - review
  - PR
  - pull request
  - check code
---

# Code Review Skill

## When This Activates
- Reviewing any code changes
- Before merging PRs
- Self-review before committing

## Review Dimensions

### 1. Correctness
- Does it do what it's supposed to?
- Edge cases handled?
- Error cases covered?
- Null/undefined checks?

### 2. Security
- Input validation?
- Output encoding?
- Auth/authz correct?
- No secrets in code?
- SQL injection safe?
- XSS prevention?

### 3. Performance
- N+1 queries?
- Unnecessary re-renders?
- Memory leaks?
- Large bundle impact?
- Efficient algorithms?

### 4. Maintainability
- Clear naming?
- Single responsibility?
- Proper abstractions?
- Not over-engineered?
- Easy to understand?

### 5. Testing
- Tests exist?
- Tests meaningful?
- Edge cases covered?
- Mocks appropriate?

## Output Format
```markdown
## Code Review: [File/PR]

### Verdict: ✅ Approved | ⚠️ Changes Requested | ❌ Blocked

### Critical (Must Fix)
- [ ] Issue 1 (line X)
- [ ] Issue 2 (line Y)

### Suggestions (Should Consider)  
- [ ] Suggestion 1
- [ ] Suggestion 2

### Nitpicks (Optional)
- Minor style issue

### Praise 👏
- What was done well
```
