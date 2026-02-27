---
name: search
description: Search codebase, memory, and documentation
arguments:
  - name: query
    required: true
    description: Search query
  - name: scope
    required: false
    description: "code | memory | docs | all"
    default: all
---

# Search - Universal Search

Search across codebase, memory, and documentation.

## Search Scopes

### Code (default)
Search the current codebase.
```
/search "validateUser"
/search "TODO" --scope code
```

### Memory
Search saved patterns, solutions, and decisions.
```
/search "jwt authentication" --scope memory
```

### Docs
Search documentation files.
```
/search "deployment" --scope docs
```

### All
Search everywhere (default).
```
/search "error handling"
```

## Search Types

### Exact Match
```
/search "function validateUser"
```

### Pattern Match
```
/search "validate*"
/search "*.test.ts"
```

### Regex
```
/search --regex "async\s+function\s+\w+"
```

### Semantic (Memory only)
```
/search --semantic "how to handle auth errors"
```

## Code Search

Uses ripgrep-style search:
```bash
# Find function definitions
/search "function handleLogin"

# Find imports
/search "import.*from 'react'"

# Find TODO/FIXME
/search "TODO|FIXME"

# Search specific file types
/search "useState" --type tsx
```

## Memory Search

Searches:
- `~/.claude/learning/patterns/` - Saved patterns
- `~/.claude/learning/solutions/` - Bug fixes
- Memory collections (decisions, code_patterns, etc.)

```
Results include:
- Pattern ID
- Title
- Domain/Category
- Relevance score
- Usage count
```

## Documentation Search

Searches:
- `.md` files in project
- `docs/` directories
- README files
- Code comments (JSDoc, GoDoc)

## Output Format

```
SEARCH RESULTS
==============
Query: "authentication"
Scope: all
Results: 15

CODE (8 results)
----------------
src/auth/login.ts:45
  async function authenticateUser(credentials) {

src/auth/middleware.ts:12
  // Authentication middleware

src/api/routes.ts:89
  router.post('/auth', authHandler)

[...]

MEMORY (4 results)
------------------
[Pattern] jwt-token-refresh (backend)
  JWT token refresh pattern with auto-renewal
  Used: 5 times | Success: 90%

[Solution] auth-session-timeout (bugs)
  Fix for session timeout not triggering logout
  Created: 2024-01-15

[Decision] ADR-007: JWT vs Session Auth
  Decision to use JWT for API authentication
  Status: Accepted

[...]

DOCS (3 results)
----------------
docs/API.md:156
  ## Authentication
  All API requests require a valid JWT token...

README.md:45
  ### Setup Authentication
  Configure your auth provider...

[...]
```

## Filters

```
--type [ext]      Filter by file extension
--path [pattern]  Filter by path pattern
--modified [days] Files modified in last N days
--limit [n]       Max results (default: 20)
```

## Agent Dispatch

Primary: @explorer (for code navigation)
Support: None (read-only search)
