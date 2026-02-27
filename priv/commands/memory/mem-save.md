---
name: mem:save
description: Save important context to persistent memory
arguments:
  - name: type
    required: true
    options: [decision, pattern, solution, context]
  - name: title
    required: true
---

# Save to Memory

Persist important information for future sessions.

## Action
1. Collect the context to save
2. Add metadata (timestamp, project, tags)
3. Store in appropriate ChromaDB collection
4. Confirm: "💾 Saved to memory: [title]"

## Collections
- decision → decisions collection
- pattern → code_patterns collection
- solution → problems_solutions collection
- context → project_context collection
