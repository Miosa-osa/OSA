---
name: memory-query-first
description: Always check memory before starting
triggers:
  - "*"
---

# Memory Query First Skill

## When This Activates
On EVERY request (always active).

## Process
1. Extract key concepts from the request
2. Query episodic memory for:
   - Similar past decisions
   - Relevant code patterns
   - Previous solutions to similar problems
3. Incorporate findings into response
4. Save new decisions/patterns to memory

## What to Search For
- Architecture decisions related to topic
- Code patterns for similar features
- Bug fixes for similar issues
- Team conventions and standards

## Output
Include memory findings naturally in response:
"Based on past decisions, we use [pattern] for [situation]..."
