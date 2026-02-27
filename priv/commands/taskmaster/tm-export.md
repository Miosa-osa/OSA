---
name: tm-export
description: Export tasks to markdown, JSON, or CSV
arguments:
  - name: format
    description: "Export format: md, json, csv (default: md)"
    required: false
  - name: output
    description: Output file path (default: stdout)
    required: false
  - name: filters
    description: "Optional: --project, --status, --include-done"
    required: false
---

# Export Tasks

Export tasks for sharing, backup, or external tools.

## Usage
```
/tm-export                              # Markdown to stdout
/tm-export md                           # Markdown format
/tm-export json                         # JSON format
/tm-export csv                          # CSV format
/tm-export md ./tasks.md                # Save to file
/tm-export json --project businessos    # Filter by project
```

## Format Examples

### Markdown (default)
```markdown
# Tasks Export
Generated: 2025-01-15 10:30

## In Progress (3)
- [ ] **[HIGH]** abc123: Implement auth flow
  - Tags: auth, frontend
  - Project: businessos

## Pending (5)
- [ ] **[MEDIUM]** def456: Add OAuth
  ...
```

### JSON
```json
{
  "exported": "2025-01-15T10:30:00Z",
  "tasks": [
    {
      "id": "abc123",
      "title": "Implement auth flow",
      "status": "in-progress",
      "priority": "high"
    }
  ]
}
```

### CSV
```csv
id,title,status,priority,project,tags,created
abc123,Implement auth flow,in-progress,high,businessos,"auth,frontend",2025-01-10
```

## Filter Options
- `--project <id>` - Export only from project
- `--status <status>` - Filter by status
- `--include-done` - Include completed tasks
- `--since <date>` - Tasks created after date
