---
name: help
description: Show all available commands and skills
arguments:
  - name: topic
    required: false
    description: Specific topic (tasks, memory, workflows, agents)
---

# Claude Code Help

## Quick Start
```
/prime              Load context for current project
/status             Show project status
/tm-add "task"      Add a task
/tm-next            Get next priority task
```

## Core Workflows

### Development
| Command | Description |
|---------|-------------|
| `/commit` | Create git commit with proper format |
| `/create-pr` | Create pull request |
| `/build` | Build project |
| `/test` | Run tests |
| `/lint` | Run linter with auto-fix |

### Quality
| Command | Description |
|---------|-------------|
| `/review` | Code review on changes |
| `/pr-review <n>` | Review pull request |
| `/debug <issue>` | Systematic debugging |
| `/refactor <target>` | Safe refactoring |
| `/verify` | Verification checklist |

### Analysis
| Command | Description |
|---------|-------------|
| `/explain <target>` | Explain code/concept |
| `/search <query>` | Search codebase/memory |
| `/fix <issues>` | Apply fixes from review |

## Task Management

### Basic Commands
| Command | Description |
|---------|-------------|
| `/tm-add <title>` | Add new task |
| `/tm-list` | List all tasks |
| `/tm-list pending` | List pending tasks |
| `/tm-next` | Get next priority task |
| `/tm-done <id>` | Mark task complete |
| `/tm-progress <id>` | Mark in progress |
| `/tm-delete <id>` | Delete task |

### Advanced
| Command | Description |
|---------|-------------|
| `/tm-block <id> <reason>` | Block task |
| `/tm-unblock <id>` | Unblock task |
| `/tm-priority <id> <level>` | Set priority |
| `/tm-subtask <id> <title>` | Add subtask |
| `/tm-search <query>` | Search tasks |
| `/tm-export` | Export tasks |

## Memory System

| Command | Description |
|---------|-------------|
| `/mem-search <query>` | Search memory |
| `/mem-save <type>` | Save to memory |
| `/mem-recall <topic>` | Recall memory |
| `/mem-stats` | Memory statistics |
| `/mem-list` | List memory items |

## Context Priming

| Command | Description |
|---------|-------------|
| `/prime` | General context |
| `/prime-webdev` | React/Next.js |
| `/prime-svelte` | Svelte/SvelteKit |
| `/prime-backend` | Go/Node.js backend |
| `/prime-devops` | Docker/CI/CD/GCP |
| `/prime-testing` | Testing frameworks |
| `/prime-security` | Security practices |

## System

| Command | Description |
|---------|-------------|
| `/init` | Initialize project |
| `/doctor` | Run diagnostics |
| `/status` | Project status |
| `/agents` | List all agents |
| `/analytics` | Usage analytics |

## Agents

Invoke agents directly with @name:
```
@debugger           Bug investigation
@code-reviewer      Code quality review
@security-auditor   Security analysis
@test-automator     Test writing
@refactorer         Safe refactoring
@frontend-react     React/Next.js
@frontend-svelte    Svelte/SvelteKit
@backend-go         Go development
@backend-node       Node.js development
```

Use `/agents` for full list.

## Examples

```bash
# Start a new feature
/tm-add "Implement user auth" -p high
/prime-backend
# Start coding...

# Debug an issue
/debug "Login fails with blank screen"

# Review before commit
/review
/commit

# Create PR
/create-pr

# Full workflow
/tm-next          # Get task
/prime            # Load context
# Do the work...
/test             # Run tests
/review           # Self review
/verify           # Check everything
/commit           # Commit changes
/tm-done 1        # Mark complete
```

## Legacy TaskMaster Commands

For backward compatibility with existing workflows:

### Natural Language
```
/tm-list pending high priority
/tm-add create login system with OAuth
```

### Analysis
```
/analyze-complexity    Analyze project complexity
/expand-task <id>      Break down complex task
/generate-tasks        Generate from analysis
```

### Workflows
```
/smart-workflow        Intelligent workflow
/auto-implement-tasks  Auto-implement tasks
```
