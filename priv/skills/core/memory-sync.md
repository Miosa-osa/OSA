---
name: memory-sync
description: Save important context to persistent memory
triggers:
  - decision made
  - problem solved
  - pattern discovered
  - lesson learned
---

# Memory Sync Skill

## When This Activates
- After making architectural decisions
- After solving difficult problems
- When discovering useful patterns
- After learning something important

## What to Save

### Decisions
- What was decided
- Why (context and reasoning)
- What alternatives were rejected
- Tags for future search

### Code Patterns
- Working code snippet
- When to use it
- Gotchas/caveats
- Related patterns

### Problem/Solution Pairs
- Problem symptoms
- Root cause
- Solution applied
- How to prevent recurrence

### Project Context
- Domain knowledge
- Team conventions
- External API quirks
- Environment specifics

## Memory Format
```json
{
  "type": "decision|pattern|solution|context",
  "title": "Brief descriptive title",
  "content": "Full details",
  "tags": ["tag1", "tag2"],
  "project": "project-name",
  "timestamp": "ISO date"
}
```

## Output Required
"💾 Saved to memory: [title]"
