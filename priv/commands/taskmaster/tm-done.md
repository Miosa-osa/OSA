---
name: tm:done
description: Mark a task as complete
arguments:
  - name: id
    required: true
---

# Complete Task

Mark a task as done after verification.

## Action
1. Find task by ID (partial match OK)
2. Trigger verification-before-completion skill
3. If verified, set status to "done"
4. Record completion timestamp
5. Suggest saving to memory if significant
