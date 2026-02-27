---
skill: file-based-communication
category: automation
type: communication-pattern
token_reduction: 37%
use_cases:
  - multi-agent-workflows
  - context-heavy-handoffs
  - sequential-processing
  - documentation-pipelines
created: 2026-01-28
status: active
---

# File-Based Agent Communication

Enables efficient multi-agent workflows by using files as communication medium instead of passing large context through memory/prompts.

## Core Concept

Instead of Agent B receiving Agent A's full context in a prompt:
1. Agent A writes findings to `~/work/research.md`
2. Agent B reads the file, writes to `~/work/design.md`
3. Agent C reads both files, writes to `~/work/implementation.md`
4. Orchestrator reads all files for final synthesis in fresh context

## Token Reduction Benefit

**37% token reduction** compared to traditional context passing:

| Method | Tokens Used | Cost |
|--------|-------------|------|
| Traditional (context in prompts) | 100,000 | $3.00 |
| File-based communication | 63,000 | $1.89 |

**Savings source:**
- No duplicate context in each agent's prompt
- Orchestrator loads only necessary files
- Fresh context assembly removes redundant information
- File reads are selective (only what's needed)

## When to Use

### Ideal Scenarios
- Multi-stage processing (research → design → implement → test)
- Long-running workflows with multiple handoffs
- Documentation generation pipelines
- Code generation with multiple refinement passes
- Context exceeds 20K tokens per stage

### Not Ideal For
- Single-agent tasks
- Real-time conversational interactions
- Workflows requiring <5K token context
- Simple sequential operations

## File Naming Conventions

### Standard Pattern
```
~/work/<stage>-<artifact-type>.md

Examples:
~/work/01-research.md
~/work/02-design.md
~/work/03-implementation.md
~/work/04-tests.md
~/work/05-documentation.md
```

### Alternative Patterns
```
# By agent role
~/work/backend-api-spec.md
~/work/frontend-components.md
~/work/database-schema.md

# By feature
~/work/auth-flow-research.md
~/work/auth-flow-design.md
~/work/auth-flow-implementation.md

# Timestamped
~/work/2026-01-28-research.md
~/work/2026-01-28-design.md
```

## Communication Protocol

### Stage 1: Research Agent
```markdown
# File: ~/work/01-research.md

## Problem Analysis
[Findings about the problem]

## Technical Requirements
[Identified requirements]

## Constraints
[Limitations and boundaries]

## Recommendations
[Suggested approaches]

## References
[Sources, docs, examples]
```

### Stage 2: Design Agent
```markdown
# File: ~/work/02-design.md

## Architecture Overview
[High-level design based on research]

## Components
[System components and their responsibilities]

## Data Flow
[How data moves through the system]

## API Contracts
[Interface definitions]

## Technology Choices
[Selected technologies with rationale]
```

### Stage 3: Implementation Agent
```markdown
# File: ~/work/03-implementation.md

## Files Created
- path/to/file1.go
- path/to/file2.tsx

## Implementation Notes
[Key decisions made during implementation]

## Deviations from Design
[Any changes from the design doc with rationale]

## Integration Points
[How components connect]
```

### Stage 4: Testing Agent
```markdown
# File: ~/work/04-tests.md

## Test Coverage
- Unit tests: 85%
- Integration tests: 12 scenarios
- E2E tests: 3 critical flows

## Test Results
[Pass/fail status with details]

## Edge Cases Tested
[Boundary conditions covered]

## Known Issues
[Bugs found during testing]
```

### Stage 5: Orchestrator Synthesis
```markdown
# File: ~/work/00-synthesis.md

## Project Summary
[High-level overview compiled from all stages]

## Artifacts Delivered
[List of all deliverables]

## Verification Checklist
- [ ] Research complete
- [ ] Design approved
- [ ] Implementation tested
- [ ] Documentation updated

## Next Steps
[Recommended follow-up actions]
```

## Implementation Example

### Orchestrator Script
```bash
#!/bin/bash
# File: ~/.osa/scripts/multi-agent-workflow.sh

WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"

# Stage 1: Research
echo "Stage 1: Research Agent"
claude-agent @researcher \
  --task "Research user authentication patterns" \
  --output "$WORK_DIR/01-research.md"

# Stage 2: Design
echo "Stage 2: Design Agent"
claude-agent @architect \
  --context "$WORK_DIR/01-research.md" \
  --task "Design authentication system" \
  --output "$WORK_DIR/02-design.md"

# Stage 3: Implementation
echo "Stage 3: Implementation Agent"
claude-agent @artifact-generator \
  --context "$WORK_DIR/01-research.md,$WORK_DIR/02-design.md" \
  --task "Implement authentication system" \
  --output "$WORK_DIR/03-implementation.md"

# Stage 4: Testing
echo "Stage 4: Testing Agent"
claude-agent @test-automator \
  --context "$WORK_DIR/03-implementation.md" \
  --task "Create test suite" \
  --output "$WORK_DIR/04-tests.md"

# Stage 5: Synthesis
echo "Stage 5: Orchestrator Synthesis"
claude-agent @master-orchestrator \
  --context "$WORK_DIR/*.md" \
  --task "Create project summary" \
  --output "$WORK_DIR/00-synthesis.md"

echo "Workflow complete. See $WORK_DIR/ for all artifacts."
```

### Manual Workflow
```bash
# User invokes each agent manually

# Research
@researcher please research GraphQL vs REST APIs
and save findings to ~/work/api-research.md

# Design
@architect read ~/work/api-research.md and design our API
save design to ~/work/api-design.md

# Implement
@artifact-generator read ~/work/api-design.md and generate code
save implementation notes to ~/work/api-implementation.md

# Test
@test-automator read ~/work/api-implementation.md and create tests
save test report to ~/work/api-tests.md

# Synthesize
@master-orchestrator read all ~/work/api-*.md files
and create final summary
```

## Cleanup Procedures

### After Workflow Completion
```bash
# Archive completed work
ARCHIVE_DIR="$HOME/.osa/archives/$(date +%Y-%m-%d)"
mkdir -p "$ARCHIVE_DIR"
mv ~/work/*.md "$ARCHIVE_DIR/"

# Or delete if not needed
rm ~/work/*.md
```

### Automated Cleanup Hook
```bash
# File: ~/.osa/hooks/post-workflow-cleanup.sh

# Archive work files older than 7 days
find ~/work -name "*.md" -mtime +7 -exec mv {} ~/.osa/archives/ \;

# Delete archived files older than 30 days
find ~/.osa/archives -name "*.md" -mtime +30 -delete
```

### Selective Cleanup
```bash
# Keep synthesis, delete intermediates
rm ~/work/01-research.md
rm ~/work/02-design.md
rm ~/work/03-implementation.md
rm ~/work/04-tests.md
# Keep ~/work/00-synthesis.md
```

## Best Practices

### File Organization
1. Use numbered prefixes for sequential stages (01-, 02-, 03-)
2. Include timestamps for long-running projects
3. Keep one artifact per file for clarity
4. Use descriptive names that indicate content

### Context Management
1. Each agent reads ONLY the files it needs
2. Include "References" section pointing to source files
3. Orchestrator reads all files but in fresh context
4. Archive completed workflows to prevent context pollution

### Error Handling
1. Each agent validates input file exists before reading
2. Write partial results even if agent fails mid-task
3. Include "Status" section in each file (COMPLETE/PARTIAL/FAILED)
4. Orchestrator checks all file statuses before synthesis

### Documentation
1. Each file should be self-contained and readable by humans
2. Include context about what agent generated it
3. Add timestamps for traceability
4. Use markdown formatting for clarity

## Performance Metrics

### Token Efficiency
- Traditional context passing: 15-25K tokens per agent
- File-based: 5-10K tokens per agent
- Orchestrator synthesis: 20K tokens (vs 60K+ traditional)

### Time Efficiency
- File I/O overhead: ~50ms per file
- Context assembly time: -70% (files vs repeated prompts)
- Total workflow time: Similar or faster due to reduced context

### Cost Efficiency
- 37% token reduction = 37% cost reduction
- Example: $10 traditional workflow → $6.30 file-based

## Combination with Other Patterns

### With Skeleton-of-Thought
```
1. Generate skeleton → ~/work/00-skeleton.md
2. Parallel agents expand each section → ~/work/section-*.md
3. Orchestrator assembles → ~/work/final.md
```

### With Memory System
```
1. Agent A → writes ~/work/research.md
2. Agent A → /mem-save research pattern "findings in research.md"
3. Agent B → /mem-search research pattern
4. Agent B → reads ~/work/research.md
5. Agent B → writes ~/work/design.md
```

### With Task Master
```
1. /tm-add "Research authentication"
2. @researcher → ~/work/01-research.md → /tm-done
3. /tm-add "Design authentication"
4. @architect → reads 01, writes ~/work/02-design.md → /tm-done
5. Continue pipeline...
```

## Troubleshooting

### File Not Found
```bash
# Add validation in agent prompts
if [ ! -f ~/work/01-research.md ]; then
  echo "ERROR: Research file not found. Run research stage first."
  exit 1
fi
```

### Context Too Large Even with Files
```bash
# Use file summarization
@summarizer read ~/work/01-research.md and create
a 500-word summary in ~/work/01-research-summary.md

# Next agent reads summary instead of full file
```

### File Conflicts
```bash
# Use locking or unique naming
~/work/auth-research-2026-01-28-14-30.md
~/work/auth-design-2026-01-28-15-45.md
```

## Real-World Example

### Full-Stack Feature Development

```bash
# Stage 1: Product research
@researcher "Research user notification preferences"
→ ~/work/notifications-research.md (8K tokens)

# Stage 2: API design
@api-designer read ~/work/notifications-research.md
"Design notification preferences API"
→ ~/work/notifications-api.md (5K tokens)

# Stage 3: Backend implementation
@backend-go read ~/work/notifications-api.md
"Implement Go API handlers"
→ ~/work/notifications-backend.md (3K tokens)
→ Generated code files

# Stage 4: Frontend implementation
@frontend-react read ~/work/notifications-api.md
"Create React preference settings component"
→ ~/work/notifications-frontend.md (3K tokens)
→ Generated component files

# Stage 5: Testing
@test-automator read ~/work/notifications-backend.md
and ~/work/notifications-frontend.md
"Create integration tests"
→ ~/work/notifications-tests.md (4K tokens)
→ Generated test files

# Stage 6: Documentation
@technical-writer read all ~/work/notifications-*.md
"Create user-facing documentation"
→ ~/work/notifications-docs.md (2K tokens)

# Total: 25K tokens (vs 65K+ with traditional context passing)
# Savings: 40K tokens = $1.20 saved
```

---

## References

- OSA Agent memory system: `~/.osa/docs/memory.md`
- Multi-agent orchestration: `~/.osa/docs/agents.md`
- Token optimization strategies: `~/.osa/docs/optimization.md`

## Related Skills

- `skeleton-of-thought` - Parallel content generation
- `self-consistency` - Multiple solution paths with voting
- `learning-engine` - Pattern capture and reuse
