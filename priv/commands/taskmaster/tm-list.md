---
name: tm:list
description: List all tasks with status
---

# List Tasks

Show all tasks from TaskMaster with their current status.

## Action
Read ~/.taskmaster/tasks/tasks.json and display tasks in format:
```
📋 Tasks:
⬜ 🟠 [abc123] High priority pending task
🔄 🟡 [def456] Medium priority in-progress task  
✅ 🟢 [ghi789] Completed low priority task
```

Status icons: ⬜ pending, 🔄 in-progress, 🚫 blocked, 👀 review, ✅ done
Priority icons: 🔴 critical, 🟠 high, 🟡 medium, 🟢 low
