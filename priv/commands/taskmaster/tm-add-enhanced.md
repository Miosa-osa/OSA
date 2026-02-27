---
name: tm-add
description: Add task with automatic memory search
arguments:
  - name: description
    required: true
---

# Add Task with Memory Integration

## Process

### 1. Parse Task Description
Extract:
- **Priority**: urgent, ASAP, important -> high
- **Type**: feature, bug, refactor, test, docs
- **Dependencies**: "after X", "blocked by Y"
- **Domain**: frontend, backend, database, devops

### 2. AUTO-SEARCH MEMORY
Before creating task, search for similar past tasks:

```
/mem-search "[extracted keywords from task]"
```

Query:
- `~/.claude/learning/solutions/` for similar problems
- `~/.claude/learning/patterns/` for relevant patterns
- Previous tasks with similar description

### 3. Show Memory Results

If similar tasks found:
```
+---------------------------------------------------------------------+
| MEMORY SEARCH RESULTS                                               |
+---------------------------------------------------------------------+
| Found 2 similar tasks:                                              |
|                                                                     |
| 1. "Fix JWT token expiration" (solved 3 days ago)                  |
|    Solution: Updated token refresh logic in auth.go:42             |
|    Pattern: @memory/solutions/auth-token-fix.md                    |
|    Success Rate: 100%                                               |
|                                                                     |
| 2. "Session timeout not working" (solved 1 week ago)               |
|    Solution: Fixed Redis TTL configuration                         |
|    Pattern: @memory/solutions/redis-ttl-fix.md                     |
|    Success Rate: 100%                                               |
+---------------------------------------------------------------------+
| Apply similar pattern? [yes/no/show details]                        |
+---------------------------------------------------------------------+
```

### 4. Create Task

If no pattern applied or user declines:
```
+---------------------------------------------------------------------+
| TASK CREATED                                                        |
+---------------------------------------------------------------------+
| ID:          #47                                                    |
| Description: Fix user authentication bug                            |
| Type:        bug                                                    |
| Priority:    high                                                   |
| Domain:      backend                                                |
| Status:      pending                                                |
|                                                                     |
| Suggested Agent: @debugger                                          |
| Memory Refs: None (new problem)                                     |
+---------------------------------------------------------------------+
```

If pattern applied:
```
+---------------------------------------------------------------------+
| TASK CREATED (with pattern)                                         |
+---------------------------------------------------------------------+
| ID:          #47                                                    |
| Description: Fix user authentication bug                            |
| Type:        bug                                                    |
| Priority:    high                                                   |
| Domain:      backend                                                |
| Status:      pending                                                |
|                                                                     |
| Suggested Agent: @debugger                                          |
| Applied Pattern: auth-token-fix (95% similar)                       |
| Start Point: See solution in auth.go:42                            |
+---------------------------------------------------------------------+
```

### 5. Link to Memory

On task completion, automatically:
1. Save solution if new pattern discovered
2. Update pattern usage count if pattern was used
3. Record success/failure for agent effectiveness

## Example Usage

```
/tm-add "Fix the login bug where users get logged out randomly"

# Claude:
# 1. Extracts: type=bug, domain=backend, keywords=[login, logout, random]
# 2. Searches memory for similar issues
# 3. Finds: "Session expiration bug" pattern
# 4. Shows results
# 5. Creates task with pattern reference
```
