---
name: doctor
description: Run diagnostics on the Claude Code ecosystem
---

# Doctor - System Diagnostics

Check the health of the Claude Code ecosystem setup.

## Checks Performed

### 1. Core Files
```
Check existence and validity of:
- ~/.claude/CLAUDE.md (exists, valid markdown)
- ~/.claude/settings.json (valid JSON)
- ~/.claude/mcp.json (valid JSON)
```

### 2. Directory Structure
```
Verify directories exist:
- ~/.claude/agents/
- ~/.claude/commands/
- ~/.claude/skills/
- ~/.claude/rules/
- ~/.claude/hooks/
- ~/.claude/learning/
```

### 3. Hooks
```
For each hook in ~/.claude/hooks/:
- Check file exists
- Check executable permission (755)
- Check shebang present
- Dry-run if possible
```

### 4. MCP Servers
```
For each server in mcp.json:
- Check command exists
- Check required env vars set
- Test connection if applicable
```

### 5. Environment
```
Check:
- ANTHROPIC_API_KEY set
- GITHUB_TOKEN set (if GitHub MCP used)
- Node.js version (18+)
- Git available
- Python available (if ML tools used)
```

### 6. Agents
```
For each agent in ~/.claude/agents/:
- Valid markdown format
- Has required frontmatter
- Reasonable file size
```

### 7. Commands
```
For each command in ~/.claude/commands/:
- Valid markdown format
- Has name in frontmatter
- Has description
```

## Output Format

```
CLAUDE CODE DOCTOR
==================
Running diagnostics...

Core Files:
  [OK] CLAUDE.md exists (14,633 chars)
  [OK] settings.json valid
  [OK] mcp.json valid

Directories:
  [OK] ~/.claude/agents/ (47 files)
  [OK] ~/.claude/commands/ (93 files)
  [OK] ~/.claude/skills/ (14 files)
  [OK] ~/.claude/rules/ (9 files)
  [OK] ~/.claude/hooks/ (6 files)
  [OK] ~/.claude/learning/ (exists)

Hooks:
  [OK] security-check.sh (executable)
  [OK] auto-format.sh (executable)
  [OK] validate-prompt.py (executable)
  [OK] log-session.sh (executable)
  [OK] send-event.py (executable)
  [OK] save-adr.sh (executable)

Environment:
  [OK] ANTHROPIC_API_KEY set
  [OK] GITHUB_TOKEN set
  [OK] Node.js v20.10.0
  [OK] Git 2.43.0
  [WARN] Python not found (ML tools unavailable)

MCP Servers:
  [OK] filesystem
  [OK] github
  [WARN] postgres (DATABASE_URL not set)
  [WARN] redis (REDIS_URL not set)

Summary:
--------
Status: HEALTHY (2 warnings)

Warnings:
1. Python not installed - ML training tools unavailable
2. Database MCP servers unconfigured - Set DATABASE_URL, REDIS_URL

Recommendations:
- Install Python 3.8+ for ML features
- Configure database URLs for full MCP functionality
```

## Fix Common Issues

### CLAUDE.md issues
```bash
# Check file exists and size
wc -c ~/.claude/CLAUDE.md

# Verify it's the v3.3 version
head -1 ~/.claude/CLAUDE.md
```

### Hook not executable
```bash
chmod +x ~/.claude/hooks/*.sh
chmod +x ~/.claude/hooks/*.py
```

### Missing API key
```bash
# Add to ~/.zshrc or ~/.bashrc
export ANTHROPIC_API_KEY="your-key"
source ~/.zshrc
```

### MCP server not found
```bash
# Install missing server
npm install -g @modelcontextprotocol/server-[name]
```
