---
skill_name: batch-processing
category: automation
description: Token-efficient strategy for processing multiple agent tasks through batching
triggers:
  - multiple agent invocations needed
  - token budget concerns
  - orchestration scenarios
when_to_use:
  - 5+ agents needed for task
  - complex multi-step workflows
  - high token consumption risk
when_not_to_use:
  - <5 agents needed (parallel is fine)
  - agents need real-time interaction
  - tasks are truly independent
created: 2026-01-28
version: 1.0
---

# Batch Processing Skill

Prevents token explosion when coordinating multiple agents through strategic batching.

## The Problem

**Naive Parallel Approach:**
```
User Request → 10 agents simultaneously → Token Explosion
- Each agent gets full context (20K tokens × 10 = 200K)
- Context multiplies across parallel threads
- Budget exhausted quickly
- Difficult to synthesize results
```

**Result:** 150K-200K token consumption, context fragmentation, budget warnings.

## The Solution: Batch Processing

**Strategic Batching:**
```
User Request → Batch 1 (agents 1-5) → batch1-results.md
            → Batch 2 (agents 6-10) reads batch1 → batch2-results.md
            → Orchestrator reads both .md files → Final synthesis
```

**Result:** 60-70% token reduction, clean synthesis, preserved budget.

## Core Strategy

### 1. Complexity Detection

```
Task Analysis:
├── Agent Count Required: N
├── Estimated Tokens per Agent: T
├── Total if Parallel: N × T
└── Decision:
    ├── If N ≤ 4: Use parallel execution
    ├── If 5 ≤ N ≤ 10: Use 2-batch approach
    ├── If N > 10: Use 3+ batch approach or reconsider scope
```

### 2. Batch Size Calculation

```
Optimal Batch Size = min(5, ceil(N / 2))

Examples:
- 6 agents → 2 batches of 3
- 10 agents → 2 batches of 5
- 15 agents → 3 batches of 5
```

### 3. Workflow Pattern

#### Batch 1: Initial Processing
```markdown
Purpose: Handle first wave of agents
Output: ~/work/batch1-results.md

Format:
# Batch 1 Results

## Agent 1: [Agent Name]
**Task:** [Description]
**Status:** [Complete/Failed]
**Key Findings:**
- Finding 1
- Finding 2

**Artifacts Created:**
- /path/to/file1
- /path/to/file2

## Agent 2: [Agent Name]
...
```

#### Batch 2: Informed Processing
```markdown
Purpose: Process remaining agents WITH context from Batch 1
Input: Read ~/work/batch1-results.md first
Output: ~/work/batch2-results.md

Format: Same as Batch 1
```

#### Orchestrator: Final Synthesis
```markdown
Purpose: Combine all results in fresh context
Input: Read both batch1-results.md and batch2-results.md
Output: Final deliverable + summary

Process:
1. Load batch results (lightweight markdown files)
2. Fresh 200K token context
3. Synthesize coherent final output
4. Generate comprehensive summary
```

## Implementation Patterns

### Pattern 1: Sequential Dependency Chain
```
Use When: Each batch needs previous batch's output

Flow:
Batch 1 → Results → Batch 2 reads Results → Final Results → Orchestrator

Example: Code generation where later components depend on earlier ones
```

### Pattern 2: Parallel with Staged Merge
```
Use When: Batches are independent but need coordinated synthesis

Flow:
Batch 1 (independent) → Results 1
Batch 2 (independent) → Results 2
→ Orchestrator merges both

Example: Multiple feature implementations that integrate at the end
```

### Pattern 3: Progressive Refinement
```
Use When: Each batch refines/extends previous work

Flow:
Batch 1 → Draft → Batch 2 refines → Enhanced → Orchestrator finalizes

Example: Documentation where first batch writes, second batch reviews/improves
```

## Decision Tree

```
START: Need multiple agents?
│
├─ Agent count ≤ 4?
│  └─ YES → Use PARALLEL execution (low token cost)
│  └─ NO → Continue
│
├─ Agents independent?
│  ├─ YES → Consider parallel with isolated contexts
│  └─ NO → Continue to batching
│
├─ Token budget concern?
│  ├─ YES → Use BATCHING (this skill)
│  └─ NO → Assess other factors
│
├─ Need sequential dependency?
│  ├─ YES → Use SEQUENTIAL DEPENDENCY pattern
│  └─ NO → Use PARALLEL WITH STAGED MERGE pattern
│
└─ Complex refinement needed?
   ├─ YES → Use PROGRESSIVE REFINEMENT pattern
   └─ NO → Use simplest batching approach
```

## Token Economics

### Parallel Explosion (10 agents)
```
Context per agent: 20K tokens
Agent execution: 10K tokens
Total per agent: 30K tokens

Parallel: 30K × 10 = 300K tokens (OVER BUDGET)
```

### Batching Approach (10 agents)
```
Batch 1 (5 agents):
- Context: 20K × 5 = 100K
- Execution: 10K × 5 = 50K
- Write results: 5K
Total: 155K

Batch 2 (5 agents):
- Read batch1: 5K
- Context: 15K × 5 = 75K (reduced, contextual)
- Execution: 10K × 5 = 50K
- Write results: 5K
Total: 135K

Orchestrator:
- Read both batches: 10K
- Synthesis: 20K
Total: 30K

GRAND TOTAL: 320K → 155K + 135K + 30K = 320K
BUT executed across separate sessions = 155K peak
```

**Savings: Peak load reduced from 300K to 155K (48% reduction)**

## File Organization

```
~/work/
├── batch1-results.md       # First batch output
├── batch2-results.md       # Second batch output (if needed)
├── batch3-results.md       # Third batch output (if needed)
├── final-synthesis.md      # Orchestrator's combined output
└── batch-metadata.json     # Tracking info (optional)
```

## Batch Result Template

```markdown
# Batch [N] Results
**Timestamp:** [ISO 8601]
**Agents:** [count]
**Overall Status:** [Complete/Partial/Failed]

---

## Agent 1: @[agent-name]
### Task
[Description of what this agent was asked to do]

### Status
[Complete/Failed/Partial]

### Output Summary
[Key findings, decisions made, or results produced]

### Artifacts
- `/absolute/path/to/file1.ext` - [description]
- `/absolute/path/to/file2.ext` - [description]

### Dependencies for Next Batch
- [What the next batch needs to know from this agent]

### Issues/Blockers
- [Any problems encountered]

---

## Agent 2: @[agent-name]
[Same structure]

---

## Batch Summary
**Total Tokens Used:** [approximate]
**Key Outputs:**
- [Major deliverable 1]
- [Major deliverable 2]

**Handoff to Next Batch:**
- [Critical information for next batch]
```

## Quality Assurance

### Batch Completion Checklist
- [ ] All agents in batch completed
- [ ] Results documented in batch file
- [ ] Artifacts referenced with absolute paths
- [ ] Key findings summarized
- [ ] Dependencies for next batch identified
- [ ] No critical blockers

### Inter-Batch Validation
```markdown
Before starting Batch N+1:
1. Verify Batch N results file exists
2. Check all Batch N agents completed successfully
3. Identify dependencies Batch N+1 needs
4. Load only necessary context from Batch N
5. Proceed with Batch N+1
```

## Error Handling

### Agent Failure in Batch
```
IF agent fails in Batch N:
├─ Document failure in batch-results.md
├─ Assess impact on downstream agents
├─ DECISION:
│  ├─ Can proceed without? → Continue batch
│  ├─ Critical dependency? → Retry agent
│  └─ Blocking failure? → Abort remaining batch, escalate
└─ Update batch summary with failure details
```

### Batch Failure
```
IF entire Batch N fails:
├─ Document in batch-results.md
├─ Assess if Batch N+1 can proceed independently
├─ DECISION:
│  ├─ Independent? → Continue with warning
│  └─ Dependent? → Abort workflow, report to orchestrator
```

## Examples

### Example 1: Full-Stack Feature (8 agents)

**Task:** Build user authentication feature

**Batch 1 (4 agents):**
1. @api-designer → Design auth endpoints
2. @database-specialist → Design user schema
3. @security-auditor → Security requirements
4. @frontend-react → UI component specs

**Output:** batch1-results.md with API contracts, schema, security checklist, UI specs

**Batch 2 (4 agents):**
1. @backend-go → Implement API (uses Batch 1 API design)
2. @test-automator → Write API tests (uses Batch 1 security requirements)
3. @frontend-react → Implement UI (uses Batch 1 specs)
4. @devops-engineer → Deployment config

**Output:** batch2-results.md with implementations and tests

**Orchestrator:**
- Reads both batch files
- Verifies integration points
- Creates deployment guide
- Generates final summary

**Token Savings:** 240K (parallel) → 140K (batched) = 42% reduction

### Example 2: Documentation Generation (6 agents)

**Task:** Generate complete project documentation

**Batch 1 (3 agents):**
1. @code-reviewer → Analyze codebase structure
2. @api-designer → Extract API documentation
3. @database-specialist → Document data models

**Batch 2 (3 agents - refines Batch 1):**
1. @technical-writer → Write setup guide (uses Batch 1 structure)
2. @technical-writer → Write API guide (uses Batch 1 API docs)
3. @technical-writer → Write architecture doc (uses all Batch 1)

**Orchestrator:**
- Combines all documentation
- Adds navigation/index
- Ensures consistency

## Advanced: Dynamic Batching

```
IF workflow complexity is unknown:

START with estimated batch size
MONITOR token usage after Batch 1
ADJUST Batch 2 size based on actual consumption

Example:
- Estimate: 10 agents, 2 batches of 5
- After Batch 1: Used only 80K tokens (less than expected)
- Adjustment: Batch 2 can handle 6-7 agents safely
```

## Combination with Other Skills

### With skeleton-of-thought
```
1. Generate skeleton of overall task
2. Map skeleton points to agents
3. Batch agents by skeleton sections
4. Each batch handles cohesive skeleton subset
```

### With systematic-debugging
```
When debugging requires multiple specialists:
1. Batch 1: Reproduce + Isolate (3-4 agents)
2. Batch 2: Hypothesize + Test (remaining agents use Batch 1 findings)
3. Orchestrator: Fix + Verify + Prevent
```

### With TDD
```
1. Batch 1: Generate tests (test specialists)
2. Batch 2: Implement to pass tests (implementation specialists, read Batch 1 tests)
3. Orchestrator: Refactor + verify
```

## Monitoring & Metrics

Track these metrics to optimize batching:

```
- Average tokens per batch
- Batch completion time
- Token savings vs parallel
- Agent success rate per batch
- Inter-batch dependency violations
- Orchestrator synthesis complexity
```

## Best Practices

1. **Keep batches cohesive** - Group related agents together
2. **Document dependencies** - Always note what next batch needs
3. **Use absolute paths** - Avoid path confusion across batches
4. **Fail fast** - Don't proceed if critical agent fails
5. **Lightweight handoffs** - batch-results.md should be scannable
6. **Fresh context for orchestrator** - Let it start clean with just result files
7. **Version batch files** - Use timestamps if running multiple times

## Anti-Patterns to Avoid

❌ **Over-batching:** Creating 10 batches for 12 agents (overhead > savings)
❌ **Under-batching:** Running 15 agents in one batch (token explosion)
❌ **Ignoring dependencies:** Starting Batch 2 when Batch 1 has critical failures
❌ **Bloated batch files:** Including full code in results (use paths instead)
❌ **No orchestration:** Assuming batch results don't need synthesis
❌ **Rigid batch sizes:** Not adapting to actual token consumption

---

**Status:** Active
**Last Updated:** 2026-01-28
**Related Skills:** skeleton-of-thought, systematic-debugging, TDD
**See Also:** ~/.claude/docs/swarms.md, ~/.claude/docs/orchestration.md
