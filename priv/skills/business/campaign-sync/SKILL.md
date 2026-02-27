---
name: campaign-sync
description: Track marketing campaigns and channel performance metrics
tools: [file_read, file_write, shell_execute, memory_save]
trigger: campaign|marketing|channel|performance|ab test|conversion
priority: medium
---

# Campaign Sync

Track and analyze marketing campaign performance across channels.

## Capabilities
- Maintain campaign records in ~/.osa/data/campaigns.json
- Track channel-specific metrics (impressions, clicks, conversions, spend)
- Record A/B test variants and results
- Calculate ROI, CPA, and ROAS per channel
- Generate performance comparison reports

## Workflow
1. Parse campaign action from user request
2. Load current campaign data
3. Apply updates (new campaign, metrics update, A/B result)
4. Calculate derived metrics
5. Save updated state and report results

## Data Format
```json
{
  "id": "camp_xxxx",
  "name": "...",
  "channels": {
    "channel_name": {
      "impressions": 0,
      "clicks": 0,
      "conversions": 0,
      "spend_usd": 0
    }
  },
  "ab_tests": [],
  "status": "active",
  "created_at": "ISO8601"
}
```
