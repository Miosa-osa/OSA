---
name: mem:search
description: Search episodic memory for past decisions, patterns, solutions
arguments:
  - name: query
    required: true
---

# Memory Search

Search ChromaDB memory for relevant past context.

## Action
1. Query all collections (decisions, code_patterns, problems_solutions, project_context)
2. Rank results by relevance
3. Return top 5 results with:
   - Title
   - Summary
   - When it was saved
   - Relevance score
4. Suggest related searches if results are sparse
