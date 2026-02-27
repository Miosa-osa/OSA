---
name: tm-block
description: Mark a task as blocked with reason
arguments:
  - name: id
    description: Task ID to block
    required: true
  - name: reason
    description: Why the task is blocked
    required: true
---

# Block Task

Mark a task as blocked, indicating it cannot proceed.

## Usage
```
/tm-block <id> <reason>
```

## Examples
```
/tm-block abc123 "Waiting for API credentials from client"
/tm-block abc123 "Depends on TASK-456 to be completed first"
/tm-block abc123 "Need design mockups from UI team"
/tm-block abc123 "Blocked by production bug #789"
```

## Behavior
1. Find task by ID
2. Set status to "blocked"
3. Add blockedReason field with timestamp
4. Show warning about blocked task

## Output Format
```
⚠️ TASK BLOCKED
ID: abc123
Title: Implement auth flow
Blocked: Waiting for API credentials from client
Since: 2025-01-15 10:30
```

## See Also
- `/tm-unblock` - Remove blocked status
- `/tm-list blocked` - Show all blocked tasks
