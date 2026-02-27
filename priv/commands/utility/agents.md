---
name: agents
description: List all available agents and their capabilities
arguments:
  - name: filter
    required: false
    description: Filter by category (elite, combat, frontend, backend, quality, etc.)
---

# Agents - Agent Roster

Display all available agents organized by tier and specialty.

## Agent Tiers

### Tier 1: Orchestration (Opus Model)
Complex reasoning, multi-step tasks, architectural decisions.

| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Master Orchestrator | @master-orchestrator | Multi-agent coordination |
| Architect | @architect | System design, ADRs |

### Tier 2: Elite Specialists (Opus Model)
High-performance, specialized expertise.

| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Dragon | @dragon | Ultra-high-performance Go (10K RPS) |
| Oracle | @oracle | AI/ML, fine-tuning |
| Nova | @nova | AI platform serving |
| Blitz | @blitz | Microsecond latency (<100us) |

### Tier 3: Combat Specialists (Sonnet Model)
Domain experts for specific technical areas.

| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Angel | @angel | DevOps, CI/CD, Kubernetes |
| Cache | @cache | Database caching, Redis |
| Parallel | @parallel | Go concurrency, goroutines |
| Quantum | @quantum | Real-time systems |

### Tier 4: Domain Specialists (Sonnet Model)

#### Frontend
| Agent | Invoke | Specialty |
|-------|--------|-----------|
| React Expert | @frontend-react | React, Next.js, shadcn/ui |
| Svelte Expert | @frontend-svelte | Svelte, SvelteKit |
| UI/UX Designer | @ui-ux-designer | Design systems, accessibility |
| Tailwind Expert | @tailwind-expert | Tailwind CSS |
| TypeScript Expert | @typescript-expert | Advanced types |

#### Backend
| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Go Expert | @backend-go | Go, Chi, Echo |
| Node Expert | @backend-node | Node.js, Express, NestJS |
| Go Concurrency | @go-concurrency | Goroutines, channels |
| ORM Expert | @orm-expert | Prisma, Drizzle |
| Database Specialist | @database-specialist | PostgreSQL, optimization |
| API Designer | @api-designer | REST, GraphQL, OpenAPI |

#### Quality
| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Code Reviewer | @code-reviewer | Code quality, best practices |
| Security Auditor | @security-auditor | OWASP, vulnerabilities |
| Test Automator | @test-automator | Test frameworks, coverage |
| Debugger | @debugger | Bug investigation |
| Performance Optimizer | @performance-optimizer | Profiling, optimization |
| QA Engineer | @qa-engineer | Test strategy, quality |

#### Infrastructure
| Agent | Invoke | Specialty |
|-------|--------|-----------|
| DevOps Engineer | @devops-engineer | Docker, CI/CD, GCP |
| Migrator | @migrator | Version upgrades |

#### Specialized
| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Refactorer | @refactorer | Safe code improvement |
| Technical Writer | @technical-writer | Documentation |
| Product Manager | @product-manager | Requirements, prioritization |
| SSE Specialist | @sse-specialist | Server-Sent Events |
| MCP Specialist | @mcp-specialist | MCP server integration |
| E2B Specialist | @e2b-specialist | E2B sandbox |

### Tier 5: Utility Agents (Haiku Model)
Quick, simple tasks.

| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Explorer | @explorer | Codebase navigation |
| Doc Writer | @doc-writer | Quick documentation |
| Dependency Analyzer | @dependency-analyzer | Package analysis |

### Meta Agents (Opus Model)

| Agent | Invoke | Specialty |
|-------|--------|-----------|
| Agent Creator | @agent-creator | Create new agents |
| Codebase Analyzer | @codebase-analyzer | Deep analysis |

## Auto-Dispatch Rules

Agents are automatically selected based on:

**By File Extension:**
- `.svelte` → @frontend-svelte
- `.tsx`, `.jsx` → @frontend-react
- `.go` → @backend-go
- `.sql` → @database-specialist
- `.prisma` → @orm-expert

**By Keywords:**
- "bug", "error" → @debugger
- "test", "coverage" → @test-automator
- "review" → @code-reviewer
- "security" → @security-auditor
- "deploy", "docker" → @devops-engineer
- "slow", "performance" → @performance-optimizer

**By Directory:**
- BusinessOS-frontend → @businessos-frontend
- BusinessOS-backend → @businessos-backend

## Usage

```
# List all agents
/agents

# Filter by category
/agents frontend
/agents quality
/agents elite

# Get info about specific agent
/agent-info @debugger
```
