---
name: tm:next
description: Get the next priority task to work on
---

# Next Task

Get the highest priority pending task.

## Action
1. Read tasks from ~/.taskmaster/tasks/tasks.json
2. Filter to pending/in-progress tasks
3. Sort by priority (critical > high > medium > low)
4. Return top task with context
5. Ask if user wants to start working on it
