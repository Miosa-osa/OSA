---
name: batch-run
category: automation
trigger: /batch-run
description: Execute complex tasks using intelligent agent batching
performance:
  token_savings: "60-77%"
  speed_improvement: "50%"
  quality: "Higher due to dedicated context per batch"
---

# Batch Run Skill

Execute complex multi-agent tasks using intelligent batching to optimize token usage and improve quality.

## Usage

```bash
/batch-run "<task description>"
```

## Examples

```bash
# Full-stack feature
/batch-run "Build user authentication with React frontend, Go backend, tests, and docs"

# Performance work
/batch-run "Optimize database queries and add caching layer"

# Security audit
/batch-run "Security assessment of payment processing system"

# Refactoring
/batch-run "Refactor authentication module with new design patterns"
```

## How It Works

### Phase 1: Task Analysis
- Detects complexity (1-10 scale)
- Identifies required agents based on keywords
- Maps dependencies between agents

### Phase 2: Batch Planning
- Groups agents into optimal batches (1-8 per batch)
- Prioritizes elite agents (architect, security) first
- Estimates execution time

### Phase 3: Batch Execution
- Executes batches sequentially
- Agents within each batch run in parallel
- Each batch gets dedicated 200K context
- Results written to ~/work/batchN-results.md

### Phase 4: Synthesis
- Orchestrator reads all batch results
- Synthesizes into final coherent output
- Returns comprehensive answer

## Complexity → Batch Size Mapping

| Complexity | Batch Size | Example Task |
|------------|------------|--------------|
| 1-3 | 1-2 agents | Fix typo, add logging |
| 4-5 | 3 agents | Add API endpoint with tests |
| 6-7 | 5 agents | Build feature with frontend/backend |
| 8-10 | 8 agents | Full system redesign |

## Token Economics

| Approach | 10 Agents | Tokens | Cost |
|----------|-----------|--------|------|
| Naive Parallel | All at once | 2M | $85 |
| Batch Sequential | 2 batches | 450K | $19 |
| **Savings** | - | **77%** | **77%** |

## Agent Keyword Mapping

| Keywords | Agent Assigned |
|----------|----------------|
| research, analyze, benchmark | explorer |
| design, architecture, schema | architect |
| go, api, backend, server | backend-go |
| react, frontend, ui | frontend-react |
| test, coverage, unit | test-automator |
| performance, optimize | performance-optimizer |
| security, vulnerability | security-auditor |
| docker, kubernetes, deploy | devops-engineer |
| bug, error, fix | debugger |

## Output Files

```
~/.osa/work/batches/
├── batch1-results.md    # First batch output
├── batch2-results.md    # Second batch output
├── SYNTHESIS.md         # Final combined output
└── ...
```

## Integration

Works with:
- **skeleton-of-thought**: Parallel outline generation
- **verification-chain**: Multi-agent validation
- **file-based-communication**: Agent→file→orchestrator pattern
- **extended-thinking**: Complex reasoning per agent

## Best Practices

1. **Be specific** - More detail = better agent selection
2. **Include constraints** - "with 80% test coverage"
3. **Mention technologies** - "using Go and PostgreSQL"
4. **State goals** - "optimize for latency under 100ms"

## Monitoring

```bash
# View batch metrics
python3 ~/.osa/hooks/batch-metrics.py --stats

# Check batch results
ls ~/.osa/work/batches/

# Read synthesis
cat ~/.osa/work/batches/SYNTHESIS.md
```
