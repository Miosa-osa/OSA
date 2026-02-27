---
name: hypothesis-engine
description: Generate and track business hypotheses with experiment design
tools: [file_read, file_write, memory_save, web_search]
trigger: hypothesis|experiment|test|validate|assumption
priority: medium
---

# Hypothesis Engine

Structured hypothesis generation, experiment design, and result evaluation.

## Capabilities
- Generate testable hypotheses from business observations
- Design experiments with clear success criteria
- Track hypothesis status: Draft -> Testing -> Validated -> Invalidated
- Evaluate results against predefined thresholds
- Build decision frameworks from validated hypotheses

## Workflow
1. Capture the observation or assumption from user
2. Structure as formal hypothesis: "If [action], then [outcome], because [rationale]"
3. Design minimum viable experiment with metrics and timeline
4. Track experiment execution and data collection
5. Evaluate results and update hypothesis status
6. Generate decision recommendations

## Data Format
```json
{
  "id": "hyp_xxxx",
  "hypothesis": "If..., then..., because...",
  "status": "draft",
  "experiment": {
    "design": "...",
    "metrics": [],
    "success_criteria": "...",
    "timeline_days": 14
  },
  "results": null,
  "decision": null,
  "created_at": "ISO8601"
}
```
