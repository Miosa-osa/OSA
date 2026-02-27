---
name: tm:add
description: Add a new task
arguments:
  - name: title
    required: true
  - name: priority
    required: false
    default: medium
---

# Add Task

Add a new task to TaskMaster.

## Action
1. Generate unique task ID
2. Add to ~/.taskmaster/tasks/tasks.json
3. Set status to "pending"
4. Confirm: "✅ Task added: [title] (ID: [id])"
