---
name: init
description: Initialize Claude Code for a new project
arguments:
  - name: template
    required: false
    description: "minimal | standard | full"
    default: standard
---

# Init - Project Setup

Initialize Claude Code configuration for a new project.

## Templates

### Minimal
Basic setup for small projects.
```
Creates:
- .claude/CLAUDE.md (project overview)
```

### Standard (Default)
Recommended for most projects.
```
Creates:
- .claude/CLAUDE.md (project overview)
- .claude/settings.local.json (project preferences)
- .mcp.json (project MCP servers)
```

### Full
Complete setup for large/team projects.
```
Creates:
- .claude/CLAUDE.md (comprehensive)
- .claude/settings.local.json
- .claude/rules/ (project-specific rules)
- .mcp.json
- .taskmaster/ (TaskMaster integration)
```

## Process

### Step 1: Detect Project Type

```
Check for:
- package.json → Node.js project
- go.mod → Go project
- pyproject.toml → Python project
- Cargo.toml → Rust project

Identify framework:
- next.config.* → Next.js
- svelte.config.* → SvelteKit
- vite.config.* → Vite
```

### Step 2: Generate CLAUDE.md

```markdown
# [Project Name]

## Overview
[Auto-detected or user-provided description]

## Tech Stack
- Language: [detected]
- Framework: [detected]
- Database: [if detected]

## Directory Structure
[Auto-generated from project]

## Key Commands
- `[build command]` - Build project
- `[test command]` - Run tests
- `[dev command]` - Start development

## Conventions
[Based on detected config files]

## Important Files
- [key files identified]
```

### Step 3: Generate MCP Config (if applicable)

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-server-filesystem"],
      "env": {
        "ALLOWED_PATHS": "[project root]"
      }
    }
  }
}
```

### Step 4: Initialize TaskMaster (if full template)

```
Create:
- .taskmaster/tasks/tasks.json
- .taskmaster/config.json
```

## Output

```
PROJECT INITIALIZED
===================
Template: standard
Project: my-app (Next.js)

Created:
  [OK] .claude/CLAUDE.md (1,234 chars)
  [OK] .claude/settings.local.json
  [OK] .mcp.json

Detected:
  Language: TypeScript
  Framework: Next.js 14
  Package Manager: pnpm
  Test Framework: Jest

Next Steps:
-----------
1. Review .claude/CLAUDE.md and add project-specific info
2. Set environment variables for MCP servers
3. Run /prime to load context
4. Use /tm-add to create your first task

Quick Start:
-----------
/prime            Load project context
/status           View project status
/tm-add "task"    Add a task
```

## Customization

After initialization, edit:

1. **.claude/CLAUDE.md** - Add:
   - Team conventions
   - Architecture decisions
   - Key contacts
   - Deployment info

2. **.mcp.json** - Add:
   - Database connections
   - API integrations
   - Custom tools

3. **.claude/rules/** - Add:
   - Project-specific coding standards
   - Review requirements
   - Security policies
