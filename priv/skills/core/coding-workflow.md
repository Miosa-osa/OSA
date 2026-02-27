---
name: coding-workflow
description: "Full development workflow loop for coding tasks. Auto-triggers on implementation requests. Chains memory search, agent dispatch, TDD, review, verify, and commit into a seamless flow."
user-invocable: true
disable-model-invocation: false
---

# Coding Workflow Loop

## The Flow: UNDERSTAND -> PLAN -> IMPLEMENT -> REVIEW -> VERIFY -> COMMIT -> LEARN

### Phase 1: UNDERSTAND
Before writing any code:
1. **Memory Search** - `/mem-search` for related patterns, past solutions, decisions
2. **Context Gather** - Read existing code, understand patterns in use
3. **Requirements** - Clarify what needs to happen, identify acceptance criteria
4. **Scope** - Identify affected files, dependencies, potential impacts

### Phase 2: PLAN
Before touching code:
1. **Break Down** - Split into subtasks (use `/tm-add` for each)
2. **Architecture** - If significant: dispatch @architect for ADR
3. **Approach** - Pick the simplest approach that works
4. **Dependencies** - Map task order, identify parallelizable work

### Phase 3: IMPLEMENT (TDD Loop)
For each subtask:
```
RED:    Write failing test first
GREEN:  Write minimum code to pass
REFACTOR: Clean up while tests pass
```

Dispatch agents by context:
- `.go` files -> @backend-go
- `.tsx` files -> @frontend-react
- `.svelte` files -> @frontend-svelte
- `.sql` / schema -> @database-specialist
- Type errors -> @typescript-expert
- API endpoints -> @api-designer
- Styling -> @tailwind-expert

For complex tasks, dispatch parallel agents:
- Independent subtasks -> parallel Task calls
- Each agent gets focused scope
- Collect and integrate results

### Phase 4: REVIEW
After implementation:
1. **Self-Review** - Read your own diff, check for obvious issues
2. **Code Review** - Dispatch @code-reviewer on changed files
3. **Security Check** - If auth/input/data handling: dispatch @security-auditor
4. **Performance** - If hot path or data-heavy: dispatch @performance-optimizer

### Phase 5: VERIFY
Required evidence before claiming done:
```bash
# 1. Build passes
npm run build  # or go build ./...

# 2. Tests pass (existing + new)
npm test       # or go test ./...

# 3. No type errors
npx tsc --noEmit  # TypeScript projects

# 4. Linting clean
npm run lint   # or golangci-lint run
```

Show output as evidence. If anything fails: fix and re-verify.

### Phase 6: COMMIT
Only when verification passes:
1. Stage specific files (not `git add .`)
2. Write descriptive commit message (why, not what)
3. Use `/commit` command

### Phase 7: LEARN
After completing the task:
1. **Save Pattern** - If novel solution: `/mem-save pattern`
2. **Save Decision** - If architectural choice: `/mem-save decision`
3. **Update Metrics** - Learning hooks auto-capture this

## Parallel Execution Rules

When multiple independent tasks exist:
- Launch up to 4 agents in parallel
- Each agent gets clear, self-contained scope
- Wait for all to complete before integration
- Review integration points after merge

## Escalation Paths

| Situation | Escalate To |
|-----------|-------------|
| Standard task hits performance wall | @performance-optimizer -> @blitz |
| Go backend needs 10K+ RPS | @backend-go -> @dragon |
| Security vulnerability found | @security-auditor -> @blue-team |
| Architecture affects multiple services | @architect -> @architect-enhanced |
| Complex multi-step with 3+ phases | @master-orchestrator |

## Anti-Patterns (Don't Do This)

- Writing code without reading existing patterns first
- Skipping tests ("I'll add them later")
- Making changes beyond what was asked
- Committing without verification evidence
- Ignoring memory search results
- Over-engineering simple tasks

## Quick Reference

```
/mem-search <topic>    # Always first
/tm-add "task"         # Track work
/test                  # Run tests
/review                # Code review
/verify                # Full verification
/commit                # Git commit
/mem-save pattern      # Save learnings
```
