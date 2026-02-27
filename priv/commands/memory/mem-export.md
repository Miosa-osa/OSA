---
name: mem-export
description: Export memory collections to file
arguments:
  - name: collection
    description: "Collection to export (or 'all')"
    required: false
  - name: output
    description: Output file path
    required: false
  - name: format
    description: "Export format: json, md (default: json)"
    required: false
---

# Export Memory

Export memory collections for backup or transfer.

## Usage
```
/mem-export                                    # Export all to JSON (stdout)
/mem-export decisions                          # Export decisions
/mem-export all ./memory-backup.json           # All to file
/mem-export patterns ./patterns.md md          # Patterns as Markdown
```

## Examples
```bash
# Backup everything
/mem-export all ~/.claude/backups/memory-2025-01-15.json

# Export patterns for documentation
/mem-export patterns ./docs/patterns.md md

# Export decisions for team sharing
/mem-export decisions ./team/decisions.json
```

## JSON Format
```json
{
  "exported": "2025-01-15T10:30:00Z",
  "version": "1.0.0",
  "collection": "decisions",
  "entries": [
    {
      "id": "abc123",
      "title": "ADR-007: Use JWT for auth",
      "content": "...",
      "metadata": {
        "date": "2025-01-10",
        "tags": ["auth", "security"],
        "project": "businessos"
      }
    }
  ]
}
```

## Markdown Format
```markdown
# Memory Export: Decisions
Exported: 2025-01-15 10:30

---

## ADR-007: Use JWT for authentication
**ID:** abc123
**Date:** 2025-01-10
**Tags:** auth, security

### Content
We decided to use JWT tokens for authentication because...

---
```

## Restore
To import an exported backup:
```
# JSON backup can be imported via ChromaDB API
# or use /mem-import command (coming soon)
```
