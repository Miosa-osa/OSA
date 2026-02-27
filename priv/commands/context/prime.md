---
name: prime
description: Show what context is currently loaded (context loads automatically)
---

# Prime: Show Current Context

Context loads AUTOMATICALLY - you rarely need to run this command.

## How Auto-Context Works

```
LEVEL 1: DIRECTORY
  cd into project → Project context loads automatically

LEVEL 2: FILE
  Edit a file → File-specific patterns add automatically

LEVEL 3: TASK
  Describe what you need → Right agents activate automatically
```

## Auto-Detection Examples

| Location | File | Request | Auto-Loads |
|----------|------|---------|------------|
| BusinessOS/frontend | .svelte | "fix bug" | @frontend-svelte + @debugger |
| BusinessOS/src | .go | "add endpoint" | @backend-go + @api-designer |
| Any project | Dockerfile | "optimize" | @devops-engineer |
| Any project | .test.ts | "add tests" | @test-automator |
| Any project | any | "review code" | @code-reviewer |
| Any project | any | "security" | @security-auditor |

## Override (Rarely Needed)

Explicitly invoke an agent if auto-detection is wrong:
```
@frontend-svelte help me with this
@backend-go review this handler
```

## You Don't Need /prime-* Commands

These are now automatic:
- /prime-svelte → Auto-detected from .svelte files
- /prime-backend → Auto-detected from .go files
- /prime-devops → Auto-detected from Dockerfile/CI keywords
- /prime-testing → Auto-detected from test files
- /prime-security → Auto-detected from security keywords

Just describe what you need - the right context loads automatically.
