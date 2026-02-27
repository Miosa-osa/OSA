---
name: pipeline-tracker
description: Track sales opportunities through pipeline stages
tools: [file_read, file_write, memory_save, shell_execute]
trigger: sales|pipeline|opportunity|deal|prospect
priority: medium
---

# Pipeline Tracker

Track and manage sales opportunities through your pipeline.

## Capabilities
- Create and update deal records in ~/.osa/data/pipeline.json
- Track pipeline stages: Lead -> Qualified -> Proposal -> Negotiation -> Closed
- Schedule follow-up reminders via HEARTBEAT.md
- Calculate conversion metrics and pipeline velocity
- Generate pipeline summary reports

## Workflow
1. Parse the user's request to identify the deal and action
2. Read current pipeline state from ~/.osa/data/pipeline.json
3. Apply the requested changes (create, update stage, add notes)
4. Calculate and report relevant metrics
5. Schedule follow-ups if stage requires it

## Data Format
Each deal is stored as:
```json
{
  "id": "deal_xxxx",
  "company": "...",
  "contact": "...",
  "value": 0,
  "stage": "lead",
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "notes": [],
  "next_followup": "ISO8601"
}
```
