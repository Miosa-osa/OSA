---
name: mem-context
description: Save current conversation context to memory
arguments:
  - name: type
    description: "What to save: decision, pattern, solution, all"
    required: false
  - name: title
    description: Title for the memory entry
    required: false
---

# Save Context to Memory

Capture important context from the current conversation for future recall.

## Usage
```
/mem-context                    # Auto-detect and save all important context
/mem-context decision           # Save as architectural decision
/mem-context pattern            # Save as code pattern
/mem-context solution           # Save as problem-solution
/mem-context all               # Save everything detected
```

## Examples
```
# After making an architecture decision
/mem-context decision "ADR-008: Use SSE for notifications"

# After creating a reusable pattern
/mem-context pattern "Go middleware pattern for auth"

# After solving a bug
/mem-context solution "Fix: CORS headers for credentials"

# Let Claude auto-detect
/mem-context
```

## Auto-Detection
When called without arguments, Claude will:
1. Analyze conversation for key events
2. Identify decisions, patterns, solutions
3. Propose what to save
4. Ask for confirmation

## Output Format
```
💾 SAVING CONTEXT TO MEMORY

Detected in conversation:
1. [DECISION] Use WebSocket instead of polling
   → Save to: decisions

2. [PATTERN] Rate limiting middleware for Go
   → Save to: patterns

3. [SOLUTION] Fixed infinite loop in useEffect
   → Save to: solutions

Save all 3 items? [yes/no/select]
```

## After Saving
```
✅ CONTEXT SAVED

Saved 3 items to memory:
• decisions/abc123: ADR: Use WebSocket
• patterns/def456: Go rate limiting middleware
• solutions/ghi789: Fix useEffect infinite loop

These will be automatically recalled in future relevant contexts.
```

## Tips
- Run at end of productive sessions
- Claude will auto-prompt when detecting important context
- Saved items improve future task assistance
