---
name: implementation
description: Implement a requested feature or change completely in an existing codebase. Use for multi-file coding tasks, specifications, acceptance criteria, and requests to build or modify behavior rather than merely explain it.
tools:
  - file_read
  - file_grep
  - file_glob
  - code_symbols
  - file_write
  - file_edit
  - shell_execute
triggers:
  - implement this
  - build this
  - add this feature
  - make this change
---

# Implementation

Deliver the requested behavior through the codebase's existing seams and conventions.

## Procedure

1. Extract concrete requirements, constraints, and acceptance evidence.
2. Read project instructions and the smallest relevant slice of architecture.
3. Identify the module interface that should own the behavior.
4. Find analogous code and tests before designing a new pattern.
5. Create a task list for work with three or more dependent steps.
6. Implement in vertical slices that can be verified independently.
7. Add or update tests at the interface where callers observe the behavior.
8. Run focused checks after each slice, then the proportionate broader suite.
9. Inspect the final diff for accidental scope, generated files, secrets, and user-owned changes.
10. Audit every requirement against current evidence before claiming completion.

## Design posture

- Prefer one deep module with a small interface over logic spread across callers.
- Preserve existing conventions unless they are the cause of the requested change.
- Do not silently narrow the request to what is easiest to test.
- Keep configuration, enforcement, and displayed state sourced from the same authority.
- Do not modify unrelated dirty files.
