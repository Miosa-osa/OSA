---
name: mem-delete
description: Delete a memory entry by ID
arguments:
  - name: id
    description: Memory entry ID to delete
    required: true
  - name: force
    description: Skip confirmation (-f or --force)
    required: false
---

# Delete Memory Entry

Remove a specific entry from memory.

## Usage
```
/mem-delete <id>
/mem-delete <id> --force
/mem-delete abc123
```

## Behavior
1. Find entry by ID (searches all collections)
2. Show entry details for confirmation
3. Delete from ChromaDB collection
4. Show confirmation

## Confirmation Prompt
```
⚠️  DELETE MEMORY ENTRY?

ID: abc123
Collection: decisions
Title: ADR-007: Use JWT for authentication
Created: 2025-01-10
Tags: auth, security, jwt

Content Preview:
"We decided to use JWT tokens for authentication because..."

Type 'yes' to confirm deletion, or 'no' to cancel:
```

## With --force
Skips confirmation and deletes immediately.

## Warning
- This action cannot be undone
- Deleted entries are permanently removed from ChromaDB
- Consider exporting before bulk deletions
