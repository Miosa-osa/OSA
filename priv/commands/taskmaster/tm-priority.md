---
name: tm-priority
description: Change task priority quickly
arguments:
  - name: id
    description: Task ID
    required: true
  - name: level
    description: "Priority level: critical, high, medium, low"
    required: true
---

# Set Task Priority

Quick shortcut to change task priority.

## Usage
```
/tm-priority <id> <level>
```

## Examples
```
/tm-priority abc123 critical
/tm-priority abc123 high
/tm-priority abc123 medium
/tm-priority abc123 low
```

## Priority Levels (highest to lowest)
1. `critical` - Drop everything, do this now
2. `high` - Important, do soon
3. `medium` - Normal priority (default)
4. `low` - Nice to have, do when time permits

## Shortcuts
- `c` or `crit` → critical
- `h` → high
- `m` or `med` → medium
- `l` → low

## Behavior
1. Find task by ID
2. Update priority
3. Re-sort task list by priority
4. Show confirmation
