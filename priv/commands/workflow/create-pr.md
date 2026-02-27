---
name: create-pr
description: Create a pull request with proper format
arguments:
  - name: title
    required: false
  - name: base
    required: false
    default: main
---

# Create Pull Request Workflow

Create a well-formatted pull request following best practices.

## Pre-PR Checks

1. **Verify Branch State**
   ```bash
   git status
   git log origin/main..HEAD --oneline
   git diff main...HEAD --stat
   ```

2. **Ensure Quality**
   - All tests pass
   - Linting passes
   - No merge conflicts
   - Branch is up to date with base

3. **Review Changes**
   - All commits are meaningful
   - No debug code left
   - No TODO comments without tickets

## PR Format

```markdown
## Summary
[1-3 bullet points describing the change]

## Changes
- [Specific change 1]
- [Specific change 2]
- [Specific change 3]

## Test Plan
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed
- [ ] Edge cases verified

## Screenshots (if UI changes)
[Before/After screenshots]

## Related Issues
Closes #XXX
```

## Action Steps

1. **Gather Information**
   - Get all commits in branch
   - Analyze changes across commits
   - Identify affected areas

2. **Create Branch if Needed**
   ```bash
   git checkout -b feature/branch-name
   ```

3. **Push to Remote**
   ```bash
   git push -u origin HEAD
   ```

4. **Create PR**
   ```bash
   gh pr create --title "Title" --body "Body"
   ```

5. **Add Labels/Reviewers** (if applicable)
   ```bash
   gh pr edit --add-label "enhancement"
   gh pr edit --add-reviewer username
   ```

## Post-Creation

1. Share PR link with team
2. Update related tasks/issues
3. Monitor CI status
