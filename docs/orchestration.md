# Agent Orchestration & Swarm Guide

> Multi-agent coordination, roles, waves, and swarm patterns

## Overview

OSA's orchestration system coordinates up to 10 parallel agents across 9 specialized roles, executing in 5 dependency-aware waves. The swarm system provides 4 execution patterns and 10 presets for common workflows.

## Architecture

```
User Request
    │
    ▼
┌─────────────┐
│ Orchestrator │─── Decomposes task into subtasks
│  (Lead)      │─── Assigns roles and tiers
└──────┬──────┘─── Builds dependency graph
       │
       ▼
┌─────────────────────────────────────────┐
│           Wave Execution                 │
│                                          │
│  Wave 1 (Foundation)  ──►  backend, data │
│  Wave 2 (Logic)       ──►  frontend, qa  │
│  Wave 3 (Presentation)──►  design        │
│  Wave 4 (Review)      ──►  red_team, qa  │
│  Wave 5 (Synthesis)   ──►  lead          │
│                                          │
│  Each wave waits for dependencies        │
│  Agents run in parallel within waves     │
└──────┬──────────────────────────────────┘
       │
       ▼
┌─────────────┐
│  Synthesis   │─── Merges results
│  (Lead)      │─── Returns unified response
└─────────────┘
```

## 9 Agent Roles

| Role | Purpose | Typical Tier | Agents |
|------|---------|-------------|--------|
| **lead** | Orchestration, architecture decisions | Elite | master-orchestrator, architect |
| **backend** | Server-side code, APIs, databases | Specialist | backend-go, database-specialist |
| **frontend** | UI code, components, styling | Specialist | frontend-react, frontend-svelte |
| **data** | Data pipelines, analytics, ETL | Specialist | database-specialist |
| **design** | UX/UI design, design systems | Specialist | ui-ux-designer |
| **infra** | DevOps, K8s, CI/CD, deployment | Specialist | devops-engineer, angel |
| **qa** | Testing, quality gates, coverage | Specialist | test-automator, qa-engineer |
| **red_team** | Security audit, adversarial testing | Specialist | security-auditor, red-team |
| **services** | APIs, integrations, third-party | Specialist | api-designer |

## 3-Tier Model Routing

| Tier | Models | Budget | Use Case |
|------|--------|--------|----------|
| **Elite** (Opus) | Claude Opus, GPT-4o | Highest | Orchestration, complex architecture |
| **Specialist** (Sonnet) | Claude Sonnet, GPT-4o-mini | Medium | Implementation, analysis |
| **Utility** (Haiku) | Claude Haiku, GPT-3.5-turbo | Lowest | Classification, quick tasks |

Each agent is assigned a tier based on its role. The tier determines which model is used and the token budget allocated.

## Triggering Orchestration

### CLI
```
/orchestrate "Build a REST API with authentication, tests, and documentation"
```

### Programmatic (Skill)
The `orchestrate` skill is invoked by the agent when it determines a task needs decomposition:
```
Complexity detected: 7/10 → spawning 5 agents across 3 waves
```

### HTTP API
```bash
curl -X POST http://localhost:8089/orchestrate \
  -H "Content-Type: application/json" \
  -d '{"task": "Refactor the user module with full test coverage"}'
```

Check progress:
```bash
curl http://localhost:8089/orchestrate/<task_id>/progress
```

## Wave Execution Detail

### Wave 1: Foundation
- **Who**: backend, data, infra
- **What**: Core logic, database schemas, infrastructure setup
- **Dependencies**: None (first wave)

### Wave 2: Logic
- **Who**: backend, frontend, services
- **What**: Business logic, API endpoints, integrations
- **Dependencies**: Wave 1 artifacts

### Wave 3: Presentation
- **Who**: frontend, design
- **What**: UI components, styling, UX
- **Dependencies**: Wave 2 APIs

### Wave 4: Review
- **Who**: qa, red_team
- **What**: Testing, security audit, quality gates
- **Dependencies**: Wave 3 implementation

### Wave 5: Synthesis
- **Who**: lead
- **What**: Merge all results, resolve conflicts, produce final output
- **Dependencies**: All previous waves

## Per-Agent Budget Caps

Each agent gets an independent token budget based on its tier:

```elixir
# Budget allocation
elite:      unlimited (within daily cap)
specialist: 40% of system prompt budget
utility:    30% of system prompt budget
```

The Budget module tracks spend per provider, per agent, per call. If an agent exceeds its budget, it's stopped gracefully.

---

## Swarm System

### 4 Execution Patterns

| Pattern | Description | Use Case |
|---------|-------------|----------|
| **parallel** | All agents run simultaneously | Independent analysis tasks |
| **pipeline** | Agent output feeds next agent's input | Sequential processing |
| **debate** | Agents argue positions, synthesis picks best | Decision-making |
| **review_loop** | Implement → review → fix → review cycle | Quality iteration |

### 10 Preset Configurations

| Preset | Agents | Pattern | Description |
|--------|--------|---------|-------------|
| `code-analysis` | 3 | parallel | Static analysis, complexity, security |
| `full-stack` | 5 | pipeline | Frontend + backend + DB + tests + deploy |
| `debug-swarm` | 3 | parallel | Multi-angle debugging |
| `performance-audit` | 4 | parallel | Profile, benchmark, optimize, verify |
| `security-audit` | 4 | parallel | OWASP, secrets, dependencies, config |
| `documentation` | 3 | pipeline | Architecture → API docs → user guide |
| `adaptive-debug` | 3 | review_loop | Debug → fix → verify cycle |
| `adaptive-feature` | 5 | pipeline | Design → implement → test → review |
| `concurrent-migration` | 4 | pipeline | Plan → migrate → test → verify |
| `ai-pipeline` | 4 | pipeline | Research → design → implement → deploy |

### Launch a Swarm

```
/swarms                    # List available patterns
/orchestrate "task"        # Auto-selects best pattern
```

HTTP API:
```bash
curl -X POST http://localhost:8089/api/v1/swarm/launch \
  -H "Content-Type: application/json" \
  -d '{"preset": "security-audit", "target": "./lib"}'
```

### PACT Framework

The swarm system uses the PACT coordination protocol:
1. **Plan** — Decompose task, assign agents
2. **Action** — Agents execute independently
3. **Coordinate** — Inter-agent messaging via Mailbox
4. **Test** — Verify combined output quality

### Inter-Agent Messaging

Agents communicate via the Swarm Mailbox:
```elixir
Swarm.Mailbox.send(from_agent, to_agent, message)
Swarm.Mailbox.receive(agent_id)
```

Messages are buffered and delivered asynchronously.

---

## 22+ Agent Roster

See all agents: `/agents`

### Elite Agents
| Name | Specialty |
|------|-----------|
| dragon | 10K+ RPS performance |
| oracle | AI/ML architecture |
| nova | AI system design |
| blitz | Sub-100μs optimization |
| architect | System architecture |

### Specialist Agents
| Name | Specialty |
|------|-----------|
| backend-go | Go APIs, Chi router |
| frontend-react | React 19, Next.js 15 |
| frontend-svelte | SvelteKit 2, runes |
| database-specialist | PostgreSQL, schema design |
| code-reviewer | Quality, security review |
| debugger | Systematic debugging |
| test-automator | TDD methodology |
| technical-writer | API docs, runbooks |
| security-auditor | OWASP, vulnerability scanning |
| devops-engineer | Docker, CI/CD, deployment |
| api-designer | REST/GraphQL design |

### Dispatching

Agents are dispatched by context:
```
.go file     → backend-go
.tsx file    → frontend-react
.svelte file → frontend-svelte
.sql file    → database-specialist
Dockerfile   → devops-engineer
"bug" keyword → debugger
"test" keyword → test-automator
"security"   → security-auditor
```

## Monitoring

```
/agents     # List agents with tiers
/tiers      # Show tier assignments and budgets
/budget     # Current spend vs limits
/usage      # Token usage breakdown
```

Real-time progress is displayed in the CLI via the TaskDisplay module during orchestration.
