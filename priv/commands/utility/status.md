---
name: status
description: Show current project and system status
---

# Status - Project Overview

Display comprehensive status of current project and Claude Code system.

## Information Gathered

### 1. Git Status
```bash
git status --short
git branch --show-current
git log -1 --format="%h %s (%cr)"
```

### 2. Project Info
```
Detect:
- Project type (Node, Go, Python, etc.)
- Framework (Next.js, SvelteKit, etc.)
- Package manager (npm, yarn, pnpm)
```

### 3. TaskMaster Status
```
From ~/.taskmaster/tasks/tasks.json:
- Total tasks
- By status (pending, in-progress, done)
- Blocked tasks
- Next priority task
```

### 4. Recent Activity
```
- Last 5 commits
- Modified files
- Staged changes
```

### 5. Test Status
```
- Last test run result
- Coverage percentage (if available)
```

### 6. Dependencies
```
- Outdated packages
- Security vulnerabilities
```

## Output Format

```
PROJECT STATUS
==============
Project: my-app
Path: /Users/name/projects/my-app
Type: Node.js (Next.js 14)

Git:
----
Branch: feature/auth
Status: 3 modified, 1 staged
Last commit: abc1234 "Add login form" (2 hours ago)
Ahead/Behind: 2 ahead, 0 behind origin/main

Tasks:
------
Total: 12
  Pending: 5
  In Progress: 2
  Done: 5
  Blocked: 1

Next Task: #7 "Implement password reset" (High)

Recent Commits:
--------------
abc1234 Add login form (2 hours ago)
def5678 Create auth service (5 hours ago)
ghi9012 Set up project structure (1 day ago)

Modified Files:
--------------
M  src/components/LoginForm.tsx
M  src/services/auth.ts
A  src/hooks/useAuth.ts

Dependencies:
------------
Outdated: 3 packages
Vulnerabilities: 0 critical, 1 moderate

Tests:
------
Last Run: 47 passed, 0 failed
Coverage: 78%

Quick Actions:
-------------
/tm-next     - Get next task
/review      - Review changes
/commit      - Commit staged changes
/test        - Run tests
```

## Agent Dispatch

Primary: @explorer (gather info)
Support: None (read-only operation)
