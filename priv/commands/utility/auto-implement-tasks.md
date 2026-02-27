Enhanced auto-implementation with **parallel execution**, intelligent code generation, and swarm coordination.

Arguments: $ARGUMENTS

## Swarm-Enhanced Auto-Implementation

Advanced implementation with **parallel task execution**, context awareness, and quality checks.

### Execution Modes

**Sequential Mode** (default for <3 tasks):
- Tasks executed one by one
- Full context available for each task
- Simpler debugging

**Parallel Mode** (auto-enabled for ≥3 independent tasks):
- **3-5x faster execution** through worker swarms
- Dependency-aware task scheduling
- Automatic worker pool management
- Real-time progress tracking

Use `/swarm-dashboard` to monitor parallel execution in real-time.

---

## PARALLEL EXECUTION WORKFLOW

### Step 1: Dependency Analysis

**Analyze TaskMaster dependency graph:**

```bash
# Get all pending tasks with dependencies
/tm/show all

# Validate dependency structure
/tm/workflows/validate-dependencies
```

**Identify independent task chains:**

Example TaskMaster output:
```
Tasks:
  A (pending) - Auth component
  B (pending, depends on A) - Auth tests
  C (pending) - Dashboard component
  D (pending, depends on C) - Dashboard tests
  E (pending) - API endpoints
  F (pending, depends on E) - API tests

Dependency Graph:
  Chain 1: A → B (Auth)
  Chain 2: C → D (Dashboard)
  Chain 3: E → F (API)

Parallelization Opportunity: 3 independent chains
Optimal Workers: 3
Estimated Speedup: 3x
```

### Step 2: Worker Pool Configuration

**Invoke swarm-coordinator for parallel execution:**

```markdown
Use the Task tool to invoke swarm-coordinator with:

Input:
- Task list: [A, B, C, D, E, F]
- Dependencies: {B: [A], D: [C], F: [E]}
- Execution mode: parallel

Swarm Coordinator will:
1. Calculate optimal worker count (typically 3-4)
2. Assign task chains to workers:
   - Worker 1: Chain 1 (A → B)
   - Worker 2: Chain 2 (C → D)
   - Worker 3: Chain 3 (E → F)
3. Spawn workers using appropriate implementation agents
4. Monitor progress and handle failures
```

### Step 3: Parallel Execution

**Worker spawning strategy:**

```
For each independent chain, spawn a specialized worker:

Worker 1 (Auth Chain):
  Agent: component-implementation-agent
  Tasks: [A: Auth component, B: Auth tests]
  Files: [src/auth/, tests/auth/]

Worker 2 (Dashboard Chain):
  Agent: component-implementation-agent
  Tasks: [C: Dashboard, D: Dashboard tests]
  Files: [src/dashboard/, tests/dashboard/]

Worker 3 (API Chain):
  Agent: feature-implementation-agent
  Tasks: [E: API endpoints, F: API tests]
  Files: [src/api/, tests/api/]
```

**File isolation ensures no conflicts** - each worker modifies different files.

### Step 4: Synchronization

**Sync point after all workers complete:**

```
Wait for all workers to finish their chains:
  Worker 1: ✓ Completed (A → B)
  Worker 2: ✓ Completed (C → D)
  Worker 3: ✓ Completed (E → F)

Sync Point Reached
→ Aggregate results
→ Validate integration
→ Check for conflicts (should be none due to file isolation)
```

### Step 5: Quality Gate Swarm

**After parallel implementation, run parallel quality checks:**

```
Spawn quality swarm (4 parallel workers):
  Worker 1: security-auditor (OWASP, vulnerabilities)
  Worker 2: performance-engineer (bottlenecks)
  Worker 3: accessibility-tester (WCAG)
  Worker 4: test-coverage-agent (missing tests)

Estimated time: 3-4 minutes (vs 12-15 minutes sequential)
```

### Step 6: Integration & Completion

**Final steps:**

```
1. Run integration tests
2. Update TaskMaster status (all tasks → completed)
3. Record metrics in collective-metrics.sh
4. Generate summary report with speedup metrics
```

---

## SEQUENTIAL EXECUTION WORKFLOW

For <3 tasks or when dependencies prevent parallelization:

### 1. **Pre-Implementation Analysis**

Before starting:
- Analyze task complexity and requirements
- Check codebase patterns and conventions
- Identify similar completed tasks
- Assess test coverage needs
- Detect potential risks

### 2. **Smart Implementation Strategy**

Based on task type and context:

**Feature Tasks**
1. Research existing patterns
2. Design component architecture
3. Implement with tests
4. Integrate with system
5. Update documentation

**Bug Fix Tasks**
1. Reproduce issue
2. Identify root cause
3. Implement minimal fix
4. Add regression tests
5. Verify side effects

**Refactoring Tasks**
1. Analyze current structure
2. Plan incremental changes
3. Maintain test coverage
4. Refactor step-by-step
5. Verify behavior unchanged

### 3. **Code Intelligence**

**Pattern Recognition**
- Learn from existing code
- Follow team conventions
- Use preferred libraries
- Match style guidelines

**Test-Driven Approach**
- Write tests first when possible
- Ensure comprehensive coverage
- Include edge cases
- Performance considerations

### 4. **Progressive Implementation**

Step-by-step with validation:
```
Step 1/5: Setting up component structure ✓
Step 2/5: Implementing core logic ✓
Step 3/5: Adding error handling ⚡ (in progress)
Step 4/5: Writing tests ⏳
Step 5/5: Integration testing ⏳

Current: Adding try-catch blocks and validation...
```

### 5. **Quality Assurance**

Automated checks:
- Linting and formatting
- Test execution
- Type checking
- Dependency validation
- Performance analysis

### 6. **Smart Recovery**

If issues arise:
- Diagnostic analysis
- Suggestion generation
- Fallback strategies
- Manual intervention points
- Learning from failures

### 7. **Post-Implementation**

After completion:
- Generate PR description
- Update documentation
- Log lessons learned
- Suggest follow-up tasks
- Update task relationships

---

## PERFORMANCE METRICS

### Automatic Metric Collection

After each execution (parallel or sequential), metrics are automatically collected:

**Parallel Execution Metrics:**
```
Swarm ID: swarm-20250117-143022
Workers: 3
Sequential Estimate: 45 minutes
Parallel Actual: 13 minutes
Speedup: 3.46x
Pattern: Parallel Task Execution
Worker Utilization: 87%
Sync Points: 2
File Conflicts: 0
```

**View Live Dashboard:**
```bash
/swarm-dashboard
```

**Export Metrics:**
```bash
~/.claude/scripts/swarm-dashboard.sh export
```

### Success Criteria

**Parallel execution considered successful when:**
- ✅ Speedup ≥ 2.0x (minimum acceptable)
- ✅ All tasks completed without errors
- ✅ Worker utilization ≥ 70%
- ✅ Zero file conflicts
- ✅ Quality gates pass

**Sequential execution considered successful when:**
- ✅ All tasks completed
- ✅ Tests pass
- ✅ Quality standards met

---

## FALLBACK & ERROR HANDLING

### Automatic Fallback to Sequential

Swarm coordinator will automatically fall back to sequential execution if:
- Dependency graph too complex (>80% sequential dependencies)
- File conflicts detected during parallel execution
- Worker failure rate >20%
- API rate limits reached

### Recovery Strategies

**Worker Failure:**
1. Retry task with same worker (1 attempt)
2. Reassign to different worker
3. Fall back to sequential for that chain
4. Escalate to user if all retries fail

**File Conflict:**
1. Detect conflict during sync point
2. Analyze conflict source
3. Attempt automatic merge
4. Escalate to user if auto-merge fails

**Performance Degradation:**
1. Monitor worker utilization
2. Detect bottlenecks (idle workers)
3. Rebalance task assignments
4. Report recommendations for next execution

---

Result: High-quality, production-ready implementations with **3-5x faster execution** through intelligent swarm coordination.