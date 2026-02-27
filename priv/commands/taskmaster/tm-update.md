---
name: tm-update
description: Update a task's fields (description, priority, tags, status)
arguments:
  - name: id
    description: Task ID to update
    required: true
  - name: field
    description: "Field to update: description, priority, tags, status, title"
    required: true
  - name: value
    description: New value for the field
    required: true
---

# Update Task

Update any field of an existing task.

## Usage
```
/tm-update <id> <field> <value>
```

## Examples
```
/tm-update abc123 title "New task title"
/tm-update abc123 priority critical
/tm-update abc123 status in-progress
/tm-update abc123 tags frontend,auth,urgent
/tm-update abc123 description "Updated description with more details"
```

## Valid Fields
- `title` - Task title
- `description` - Task description
- `priority` - critical, high, medium, low
- `status` - pending, in-progress, blocked, done
- `tags` - Comma-separated tags

## Behavior
1. Find task by ID (partial match supported)
2. Validate field and value
3. Update the field
4. Show confirmation with old → new value
