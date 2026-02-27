---
name: tm-subtask
description: Add a subtask to break down a larger task
arguments:
  - name: parent_id
    description: Parent task ID
    required: true
  - name: description
    description: Subtask description
    required: true
  - name: priority
    description: "Priority (inherits from parent if not specified)"
    required: false
---

# Add Subtask

Break down a larger task into smaller, manageable subtasks.

## Usage
```
/tm-subtask <parent_id> <description>
/tm-subtask <parent_id> <description> -p high
```

## Examples
```
/tm-subtask abc123 "Create database schema"
/tm-subtask abc123 "Write API endpoints" -p high
/tm-subtask abc123 "Add unit tests"
/tm-subtask abc123 "Write documentation"
```

## Behavior
1. Find parent task by ID
2. Create new task with parentId reference
3. Inherit priority from parent (unless specified)
4. Add to subtasks array on parent
5. Track subtask completion for parent progress

## Output Format
```
📋 SUBTASK ADDED
Parent: abc123 - Implement user authentication
Subtask: def456 - Create database schema
Priority: high (inherited)
Progress: 0/4 subtasks complete
```

## Parent Task View
When viewing a task with subtasks:
```
📋 TASK: abc123
Title: Implement user authentication
Status: in-progress
Progress: 2/4 subtasks complete (50%)
Subtasks:
  ✅ def456 - Create database schema
  ✅ def457 - Write API endpoints
  ⏳ def458 - Add unit tests
  ⏳ def459 - Write documentation
```
