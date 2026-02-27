---
name: analytics
description: Show session and learning analytics
arguments:
  - name: period
    required: false
    default: session
    options: [session, day, week, all]
---

# Analytics Dashboard

## Usage
```
/analytics              # Current session stats
/analytics day          # Today's stats
/analytics week         # This week's stats
/analytics all          # All-time stats
```

## Query Events Database

### Session Stats
```sql
SELECT
    COUNT(*) as total_events,
    COUNT(DISTINCT tool_name) as unique_tools,
    COUNT(DISTINCT agent) as agents_used,
    SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successful,
    AVG(duration_ms) as avg_duration
FROM events
WHERE timestamp > datetime('now', '-1 hour');
```

### Agent Effectiveness
```sql
SELECT
    agent,
    total_invocations,
    successful,
    failed,
    ROUND(successful * 100.0 / total_invocations, 1) as success_rate,
    ROUND(avg_duration_ms, 0) as avg_ms
FROM agent_stats
ORDER BY total_invocations DESC
LIMIT 10;
```

### Tool Usage
```sql
SELECT
    tool_name,
    COUNT(*) as uses,
    SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successful
FROM events
WHERE timestamp > datetime('now', '-24 hours')
GROUP BY tool_name
ORDER BY uses DESC;
```

## Output Format

```
+=====================================================================+
|                    ANALYTICS DASHBOARD                               |
+=====================================================================+
| Period: Current Session                                              |
| Started: 2024-01-20 14:30 UTC                                       |
+---------------------------------------------------------------------+
| SUMMARY                                                              |
+---------------------------------------------------------------------+
| Total Events:     127                                                |
| Tools Used:       8 unique                                           |
| Agents Invoked:   5                                                  |
| Success Rate:     94.5%                                              |
| Avg Duration:     1.2s                                               |
+---------------------------------------------------------------------+
| TOP AGENTS                                                           |
+---------------------------------------------------------------------+
| @backend-go       | 45 tasks | 97.8% success | 0.8s avg             |
| @debugger         | 23 tasks | 91.3% success | 2.1s avg             |
| @test-automator   | 18 tasks | 100% success  | 1.5s avg             |
| @code-reviewer    | 12 tasks | 100% success  | 0.5s avg             |
+---------------------------------------------------------------------+
| TOOL BREAKDOWN                                                       |
+---------------------------------------------------------------------+
| Read:    42 (100% success)                                           |
| Edit:    35 (97% success)                                            |
| Bash:    28 (89% success)                                            |
| Write:   15 (100% success)                                           |
| Grep:    7  (100% success)                                           |
+---------------------------------------------------------------------+
| LEARNING                                                             |
+---------------------------------------------------------------------+
| Patterns Learned:   3 new                                            |
| Solutions Saved:    2                                                |
| Memory Hits:        8 (reused past patterns)                        |
| Gaps Detected:      1 (Kubernetes specialist)                       |
+=====================================================================+
```

## Memory Check

Also query learning storage:
- `~/.claude/learning/patterns/` - Count and recent
- `~/.claude/learning/solutions/` - Count and recent
- `~/.claude/learning/gaps/detected.json` - Pending gaps
- `~/.claude/learning/metrics/` - Historical data
