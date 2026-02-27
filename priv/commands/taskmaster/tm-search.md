---
name: tm-search
description: Search tasks by text, tags, or filters
arguments:
  - name: query
    description: Search query
    required: true
  - name: filters
    description: "Optional filters: --status, --priority, --project, --tags"
    required: false
---

# Search Tasks

Search through all tasks using text or filters.

## Usage
```
/tm-search <query>
/tm-search <query> --status pending
/tm-search <query> --priority high
/tm-search <query> --project businessos
/tm-search <query> --tags auth,frontend
```

## Examples
```
/tm-search auth                           # Text search
/tm-search auth --status pending          # Pending auth tasks
/tm-search "" --priority critical         # All critical tasks
/tm-search api --project businessos       # API tasks in BusinessOS
/tm-search "" --tags urgent               # All urgent tagged tasks
```

## Search Scope
- Task title
- Task description
- Tags
- Project name
- Blocked reason

## Filter Options
- `--status` - pending, in-progress, blocked, done
- `--priority` - critical, high, medium, low
- `--project` - Project ID
- `--tags` - Comma-separated tags (matches any)
- `--created` - Date range (today, week, month)
- `--include-done` - Include completed tasks

## Output Format
```
🔍 SEARCH RESULTS: "auth" (3 matches)

1. abc123 [HIGH] Implement user authentication
   Status: in-progress | Project: businessos
   Tags: auth, frontend

2. def456 [MEDIUM] Add OAuth provider
   Status: pending | Project: businessos
   Tags: auth, oauth

3. ghi789 [LOW] Update auth documentation
   Status: pending | Project: docs
   Tags: auth, docs
```
