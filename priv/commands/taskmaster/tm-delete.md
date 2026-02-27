---
name: tm-delete
description: Delete a task permanently
arguments:
  - name: id
    description: Task ID to delete
    required: true
  - name: force
    description: Skip confirmation (-f or --force)
    required: false
---

# Delete Task

Permanently delete a task from TaskMaster.

## Usage
```
/tm-delete <id>
/tm-delete <id> --force
```

## Examples
```
/tm-delete abc123
/tm-delete abc123 -f
```

## Behavior
1. Find task by ID (partial match supported)
2. Show task details and ask for confirmation (unless --force)
3. Remove task from tasks list
4. Task is NOT moved to completedTasks (use /tm-done for that)

## Warning
This action cannot be undone. Use /tm-done instead if you want to mark as complete and keep history.
