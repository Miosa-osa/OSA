---
name: commit
description: Create a git commit with proper message format
arguments:
  - name: message
    required: false
    description: Optional commit message (auto-generated if not provided)
---

# Git Commit Workflow

Create a well-formatted git commit following best practices.

## Pre-Commit Checks

1. **Verify Changes**
   ```bash
   git status
   git diff --staged
   ```

2. **Ensure Tests Pass**
   - Run relevant test suite
   - Fix any failures before committing

3. **Check for Sensitive Data**
   - No API keys, tokens, or secrets
   - No .env files
   - No credentials

## Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting, no code change
- `refactor`: Code restructuring
- `perf`: Performance improvement
- `test`: Adding/fixing tests
- `chore`: Maintenance tasks
- `ci`: CI/CD changes

### Examples
```
feat(auth): add JWT token refresh

Implements automatic token refresh when access token expires.
Refresh happens 5 minutes before expiration.

Closes #123
```

```
fix(api): handle null response from external service

Previously crashed when service returned null.
Now returns empty array with warning log.
```

## Action Steps

1. Stage relevant files (prefer explicit files over `git add -A`)
2. Generate commit message based on changes
3. Include Co-Authored-By if pair programming
4. Create commit
5. Verify commit succeeded

## Post-Commit

1. `git log -1` to verify
2. Consider if push is needed
3. Update any related tasks
