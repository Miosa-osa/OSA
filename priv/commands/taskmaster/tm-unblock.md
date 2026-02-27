---
name: tm-unblock
description: Remove blocked status from a task
arguments:
  - name: id
    description: Task ID to unblock
    required: true
  - name: status
    description: "New status after unblocking (default: in-progress)"
    required: false
---

# Unblock Task

Remove blocked status and resume work on a task.

## Usage
```
/tm-unblock <id>
/tm-unblock <id> pending
/tm-unblock <id> in-progress
```

## Examples
```
/tm-unblock abc123                  # Sets to in-progress
/tm-unblock abc123 pending          # Sets to pending
```

## Behavior
1. Find task by ID
2. Remove "blocked" status
3. Clear blockedReason
4. Set new status (default: in-progress)
5. Add resolution note to task history

## Output Format
```
✅ TASK UNBLOCKED
ID: abc123
Title: Implement auth flow
Was blocked: Waiting for API credentials
Blocked duration: 2 days 4 hours
New status: in-progress
```
