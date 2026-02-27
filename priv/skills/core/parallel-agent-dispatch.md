---
name: parallel-agent-dispatch
description: Dispatch independent subtasks to parallel agents
triggers:
  - multiple subtasks
  - parallel
  - 3+ tasks
---

# Parallel Agent Dispatch Skill

## Trigger
Activates when task has 3+ independent subtasks.

## Process
1. **Decompose** - Break task into independent subtasks
2. **Assign** - Map each subtask to appropriate agent
3. **Execute** - Run agents in parallel
4. **Merge** - Combine results
5. **Verify** - Ensure integration works

## Agent Mapping
| Subtask Type | Agent |
|--------------|-------|
| Frontend UI | frontend-developer |
| Backend API | backend-architect |
| Database | database-specialist |
| Tests | test-automator |
| Security | security-auditor |
| Performance | performance-optimizer |
| Documentation | doc-writer |

## Output Template
```markdownParallel Execution: [Task]Subtasks

[Subtask A] → frontend-developer
[Subtask B] → backend-architect
[Subtask C] → test-automator
Results




Integration Verification
[How they work together]
