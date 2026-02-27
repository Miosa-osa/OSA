---
name: mem-list
description: List entries in memory collections
arguments:
  - name: collection
    description: "Collection to list: decisions, patterns, solutions, episodes, project_context"
    required: false
  - name: limit
    description: Number of entries to show (default 10)
    required: false
---

# List Memory Entries

Browse entries in memory collections.

## Usage
```
/mem-list                              # List all collections with counts
/mem-list decisions                    # List recent decisions
/mem-list patterns 20                  # List 20 patterns
/mem-list solutions --project miosa    # Filter by project
```

## Collections
- `decisions` - Architectural decisions (ADRs)
- `patterns` - Code patterns and solutions
- `solutions` - Problem-solution pairs
- `episodes` - Conversation episodes
- `project_context` - Project-specific knowledge

## Output Format

### Collection Summary (no args)
```
╔═══════════════════════════════════════════════════════════════════╗
║                     MEMORY COLLECTIONS                            ║
╠═══════════════════════════════════════════════════════════════════╣
║ decisions        │ 23 entries  │ Last: 2 hours ago               ║
║ patterns         │ 47 entries  │ Last: 1 day ago                 ║
║ solutions        │ 31 entries  │ Last: 3 hours ago               ║
║ episodes         │ 156 entries │ Last: 30 minutes ago            ║
║ project_context  │ 12 entries  │ Last: 1 week ago                ║
╠═══════════════════════════════════════════════════════════════════╣
║ Total: 269 entries │ Storage: 15.2 MB                            ║
╚═══════════════════════════════════════════════════════════════════╝
```

### Collection Entries
```
📚 DECISIONS (showing 10 of 23)

1. [abc123] ADR-007: Use JWT for auth
   Date: 2025-01-10 | Tags: auth, security

2. [def456] ADR-006: SSE for streaming
   Date: 2025-01-08 | Tags: sse, realtime

3. [ghi789] ADR-005: Go for backend
   Date: 2025-01-05 | Tags: go, architecture

... (7 more)
```

## Filters
- `--project <name>` - Filter by project
- `--tags <tags>` - Filter by tags
- `--since <date>` - Filter by date
- `--search <query>` - Text search within collection
