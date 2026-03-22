# Canopy Command Center — Backend Implementation Plan

> For the backend developer agent. Frontend plan: `CANOPY_FRONTEND_PLAN.md`. Master spec: `CANOPY_COMMAND_CENTER.md`.

## Context

The Canopy Command Center is a desktop app for orchestrating proactive autonomous AI agents. **This plan covers BACKEND ONLY** — the Elixir/OTP API server that the SvelteKit frontend consumes. A separate agent builds the frontend with a mock API layer, so both proceed in parallel.

The backend lives at `canopy/backend/` and serves the frontend at `canopy/desktop/`.

**Master spec**: `docs/desktop/CANOPY_COMMAND_CENTER.md` — Sections 11 (Adapter System), 12 (Backend API Surface), 13 (Real-Time Communication) are your primary references.

---

## What Backend Owns

1. **REST API** — ~80 endpoints under `/api/v1/` (see Section 12 of master spec)
2. **SSE Streams** — 3 Server-Sent Event endpoints for real-time data
3. **WebSocket** — 1 bidirectional connection for chat + inspector + live updates
4. **Adapter Runtime** — execute agent heartbeats via configured adapter (OSA, Claude Code, Codex, etc.)
5. **Heartbeat Scheduler** — cron-based proactive agent wake-up engine
6. **Budget Enforcement** — per-agent spending limits, warning thresholds, hard stops
7. **Authentication** — JWT tokens, RBAC (admin/member/viewer)
8. **Database** — PostgreSQL schemas, migrations, queries
9. **Event Bus** — internal pub/sub for SSE/WebSocket broadcast

## What Frontend Owns (NOT your concern)
- SvelteKit + Tauri desktop app
- ~218 Svelte components, 33 stores, 32 routes
- .canopy/ filesystem scanner (Tauri Rust IPC)
- Mock API layer for dev mode

---

## API Contract

The frontend defines TypeScript types in `desktop/src/lib/api/types.ts`. Your Elixir API must return JSON that matches these types exactly. The full endpoint list is in the master spec Section 12.

### Base URL
```
http://127.0.0.1:9089/api/v1/
```

### Authentication
- `POST /api/v1/auth/login` → returns JWT token
- All other endpoints require `Authorization: Bearer <token>` header
- Token refresh: frontend calls every 10 minutes
- RBAC roles: `admin` (full access), `member` (create/assign/view), `viewer` (read-only)

---

## Phase 1: Foundation (Week 1-2)

### 1.1 Project Setup
```
canopy/backend/
├── mix.exs                      Elixir project config
├── config/
│   ├── config.exs               Base config
│   ├── dev.exs                  Dev config (localhost:9089)
│   ├── prod.exs                 Production config
│   └── runtime.exs              Runtime config (env vars)
├── lib/
│   ├── canopy/                  Business logic
│   │   ├── application.ex       OTP application + supervision tree
│   │   ├── repo.ex              Ecto repo
│   │   └── ...
│   └── canopy_web/              Web layer
│       ├── router.ex            Phoenix router
│       ├── endpoint.ex          Phoenix endpoint
│       ├── controllers/         REST controllers
│       ├── channels/            WebSocket channels
│       └── plugs/               Auth, CORS, rate limiting
├── priv/
│   └── repo/migrations/         Ecto migrations
└── test/
```

### 1.2 Core Dependencies
```elixir
# mix.exs
{:phoenix, "~> 1.7"},
{:phoenix_ecto, "~> 4.5"},
{:ecto_sql, "~> 3.11"},
{:postgrex, "~> 0.18"},
{:jason, "~> 1.4"},
{:plug_cowboy, "~> 2.7"},
{:guardian, "~> 2.3"},        # JWT auth
{:quantum, "~> 3.5"},         # Cron scheduler
{:req, "~> 0.5"},             # HTTP client (for adapters)
{:cors_plug, "~> 3.0"},       # CORS
```

### 1.3 Database Schema (Initial)

```sql
-- Core tables
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR NOT NULL,
  email VARCHAR UNIQUE NOT NULL,
  password_hash VARCHAR,
  role VARCHAR NOT NULL DEFAULT 'member',  -- admin, member, viewer
  provider VARCHAR NOT NULL DEFAULT 'local',  -- local, oauth
  last_login TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE workspaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR NOT NULL,
  path VARCHAR NOT NULL,  -- filesystem path to .canopy/
  status VARCHAR NOT NULL DEFAULT 'active',
  owner_id UUID REFERENCES users(id),
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  slug VARCHAR NOT NULL,  -- filename without .md
  name VARCHAR NOT NULL,
  role VARCHAR NOT NULL,
  reports_to UUID REFERENCES agents(id),
  adapter VARCHAR NOT NULL,  -- osa, claude-code, codex, etc.
  model VARCHAR NOT NULL,
  temperature FLOAT DEFAULT 0.3,
  max_concurrent_runs INTEGER DEFAULT 1,
  status VARCHAR NOT NULL DEFAULT 'sleeping',  -- active, idle, working, sleeping, error, paused
  config JSONB DEFAULT '{}',
  system_prompt TEXT,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE(workspace_id, slug)
);

CREATE TABLE budget_policies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_type VARCHAR NOT NULL,  -- agent, project, workspace
  scope_id UUID NOT NULL,
  monthly_limit_cents INTEGER NOT NULL,
  warning_threshold_pct INTEGER NOT NULL DEFAULT 80,
  hard_stop BOOLEAN NOT NULL DEFAULT true,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE(scope_type, scope_id)
);

CREATE TABLE schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  cron_expression VARCHAR NOT NULL,
  context TEXT,  -- what agent should do when woken
  enabled BOOLEAN NOT NULL DEFAULT true,
  timezone VARCHAR DEFAULT 'UTC',
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,
  last_run_status VARCHAR,  -- success, failed, budget_stopped
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  schedule_id UUID REFERENCES schedules(id),
  model VARCHAR NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'active',  -- active, idle, completed, failed, cancelled
  tokens_input INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0,
  tokens_cache INTEGER DEFAULT 0,
  cost_cents INTEGER DEFAULT 0,
  workspace_path VARCHAR,  -- execution workspace (git worktree path)
  workspace_branch VARCHAR,
  started_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE session_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  event_type VARCHAR NOT NULL,  -- tool_call, tool_result, thinking, output, error
  data JSONB NOT NULL,
  tokens INTEGER DEFAULT 0,
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE issues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id UUID REFERENCES projects(id),
  goal_id UUID REFERENCES goals(id),
  title VARCHAR NOT NULL,
  description TEXT,
  status VARCHAR NOT NULL DEFAULT 'backlog',  -- backlog, todo, in_progress, in_review, done
  priority VARCHAR NOT NULL DEFAULT 'medium',  -- low, medium, high, critical
  assignee_id UUID REFERENCES agents(id),
  checked_out_by UUID REFERENCES agents(id),
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id UUID NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  author_type VARCHAR NOT NULL,  -- user, agent
  author_id UUID NOT NULL,
  body TEXT NOT NULL,
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  description TEXT,
  status VARCHAR NOT NULL DEFAULT 'active',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE goals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id UUID REFERENCES projects(id),
  parent_id UUID REFERENCES goals(id),
  title VARCHAR NOT NULL,
  description TEXT,
  status VARCHAR NOT NULL DEFAULT 'active',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE cost_events (
  id BIGSERIAL PRIMARY KEY,
  agent_id UUID NOT NULL REFERENCES agents(id),
  session_id UUID REFERENCES sessions(id),
  model VARCHAR NOT NULL,
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_cache INTEGER NOT NULL DEFAULT 0,
  cost_cents INTEGER NOT NULL DEFAULT 0,
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE budget_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_id UUID NOT NULL REFERENCES budget_policies(id),
  agent_id UUID NOT NULL REFERENCES agents(id),
  incident_type VARCHAR NOT NULL,  -- warning, hard_stop
  threshold_pct INTEGER NOT NULL,
  actual_pct INTEGER NOT NULL,
  resolved BOOLEAN NOT NULL DEFAULT false,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES users(id),
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE activity_events (
  id BIGSERIAL PRIMARY KEY,
  workspace_id UUID NOT NULL REFERENCES workspaces(id),
  event_type VARCHAR NOT NULL,  -- see EventType union in spec
  agent_id UUID REFERENCES agents(id),
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  level VARCHAR NOT NULL DEFAULT 'info',  -- debug, info, warn, error
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE audit_events (
  id BIGSERIAL PRIMARY KEY,
  action VARCHAR NOT NULL,
  actor VARCHAR NOT NULL,
  actor_type VARCHAR NOT NULL,  -- user, agent, system
  entity_type VARCHAR,
  entity_id UUID,
  details JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE skills (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  description TEXT,
  category VARCHAR NOT NULL,  -- Development, Research, Communication, Analysis, Operations, Custom
  trigger_rules JSONB DEFAULT '{}',
  enabled BOOLEAN NOT NULL DEFAULT true,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE agent_skills (
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  skill_id UUID NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  enabled BOOLEAN NOT NULL DEFAULT true,
  PRIMARY KEY(agent_id, skill_id)
);

CREATE TABLE memory_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id UUID REFERENCES agents(id),  -- NULL = shared memory
  key VARCHAR NOT NULL,
  content TEXT NOT NULL,
  category VARCHAR,
  tags VARCHAR[],
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE webhooks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  webhook_type VARCHAR NOT NULL,  -- incoming, outgoing
  url VARCHAR NOT NULL,
  events VARCHAR[] NOT NULL,
  secret VARCHAR,
  enabled BOOLEAN NOT NULL DEFAULT true,
  last_triggered_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE webhook_deliveries (
  id BIGSERIAL PRIMARY KEY,
  webhook_id UUID NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,
  status_code INTEGER,
  payload JSONB NOT NULL,
  response TEXT,
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE alert_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  description TEXT,
  entity VARCHAR NOT NULL,  -- Agent, Session, Budget, System, Gateway
  field VARCHAR NOT NULL,
  operator VARCHAR NOT NULL,
  value VARCHAR NOT NULL,
  cooldown_minutes INTEGER NOT NULL DEFAULT 60,
  notify_targets JSONB NOT NULL DEFAULT '["system"]',
  enabled BOOLEAN NOT NULL DEFAULT true,
  trigger_count INTEGER NOT NULL DEFAULT 0,
  last_triggered_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE alert_history (
  id BIGSERIAL PRIMARY KEY,
  rule_id UUID NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
  entity_value VARCHAR,
  resolved BOOLEAN NOT NULL DEFAULT false,
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE integrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  slug VARCHAR NOT NULL,  -- anthropic, openai, github, slack, etc.
  name VARCHAR NOT NULL,
  category VARCHAR NOT NULL,  -- ai_providers, search, social, messaging, dev_tools, security, infrastructure
  config JSONB DEFAULT '{}',  -- encrypted at rest
  connected BOOLEAN NOT NULL DEFAULT false,
  last_synced_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE(workspace_id, slug)
);

CREATE TABLE gateways (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  url VARCHAR NOT NULL,
  token VARCHAR,
  status VARCHAR NOT NULL DEFAULT 'disconnected',
  latency_ms INTEGER,
  is_primary BOOLEAN NOT NULL DEFAULT false,
  last_probe_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR NOT NULL,
  description TEXT,
  category VARCHAR NOT NULL DEFAULT 'custom',
  agents JSONB NOT NULL DEFAULT '[]',
  skills JSONB NOT NULL DEFAULT '[]',
  schedules JSONB NOT NULL DEFAULT '[]',
  is_builtin BOOLEAN NOT NULL DEFAULT false,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

### 1.4 Build Health + Dashboard Endpoints First

Priority endpoints (frontend needs these for Phase 1):

```
GET  /api/v1/health              → { status: "ok", version: "1.0.0" }
GET  /api/v1/dashboard           → { kpis, live_runs, recent_activity, finance }
POST /api/v1/auth/login          → { token, user }
POST /api/v1/auth/refresh        → { token }
```

---

## Phase 2: Core CRUD (Week 2-3)

### 2.1 Workspace Endpoints
```
GET    /api/v1/workspaces
POST   /api/v1/workspaces
GET    /api/v1/workspaces/:id
PATCH  /api/v1/workspaces/:id
DELETE /api/v1/workspaces/:id
POST   /api/v1/workspaces/:id/activate
GET    /api/v1/workspaces/:id/agents
GET    /api/v1/workspaces/:id/skills
GET    /api/v1/workspaces/:id/config
POST   /api/v1/workspaces/:id/export
POST   /api/v1/workspaces/import
```

### 2.2 Agent Endpoints
```
GET    /api/v1/agents                    # List with status, model, adapter
POST   /api/v1/agents                    # Hire agent
GET    /api/v1/agents/:id                # Full detail (joins budget, skills, last run)
PATCH  /api/v1/agents/:id                # Update config
DELETE /api/v1/agents/:id                # Terminate
POST   /api/v1/agents/:id/wake           # Trigger immediate heartbeat
POST   /api/v1/agents/:id/sleep          # Disable all schedules
POST   /api/v1/agents/:id/pause          # Temporary stop
POST   /api/v1/agents/:id/resume         # Resume from pause
POST   /api/v1/agents/:id/focus          # Block all except current task
POST   /api/v1/agents/:id/terminate      # Permanent removal
GET    /api/v1/agents/:id/runs           # Execution history
GET    /api/v1/agents/:id/inbox          # Inter-agent messages
GET    /api/v1/agents/hierarchy          # Org chart data (reports_to tree)
```

### 2.3 Session Endpoints
```
GET    /api/v1/sessions                  # List with token counts
GET    /api/v1/sessions/:id              # Session detail
GET    /api/v1/sessions/:id/transcript   # Full execution transcript
DELETE /api/v1/sessions/:id              # Terminate session
POST   /api/v1/sessions/:id/message      # Send chat message
```

### 2.4 Chat + SSE
```
POST   /api/v1/sessions/:id/message      # Send message, get session_id
GET    /api/v1/sessions/:id/stream       # SSE: streaming_token, thinking_delta, tool_call, tool_result, done, error
```

---

## Phase 3: Scheduling + Budget (Week 3-4)

### 3.1 Schedule Endpoints
```
GET    /api/v1/schedules                 # All schedules with next/last run
POST   /api/v1/schedules                 # Create schedule
GET    /api/v1/schedules/:id
PATCH  /api/v1/schedules/:id
DELETE /api/v1/schedules/:id
POST   /api/v1/schedules/:id/trigger     # Manual trigger (immediate wake)
GET    /api/v1/schedules/queue           # Pending wake-up requests
POST   /api/v1/schedules/wake-all        # Wake all agents
POST   /api/v1/schedules/pause-all       # Pause all schedules
```

### 3.2 Heartbeat Scheduler (Quantum)
- Parse cron expressions from schedules table
- On trigger: resolve adapter → create session → execute heartbeat → stream events → complete
- Each heartbeat creates an isolated execution workspace (git worktree or container)
- Respect budget policies — check before execution, track during, enforce hard stops

### 3.3 Budget + Cost Endpoints
```
GET    /api/v1/costs/summary             # { today, week, month, top_agent }
GET    /api/v1/costs/by-agent            # Per-agent breakdown
GET    /api/v1/costs/by-model            # Per-model breakdown
GET    /api/v1/costs/daily               # Daily time series (last 30 days)
GET    /api/v1/costs/events              # Raw cost events
GET    /api/v1/budgets                   # All budget policies
PUT    /api/v1/budgets/:scope_type/:scope_id  # Set/update policy
GET    /api/v1/budgets/incidents         # Budget incidents
POST   /api/v1/budgets/incidents/:id/resolve  # Resolve incident
```

### 3.4 Budget Enforcement Engine
- GenServer that tracks accumulated cost per agent/project/workspace
- On each cost event: check against policy thresholds
- 80% (configurable) → emit `budget.warning` event, create inbox notification
- 100% → emit `budget.hard_stop`, pause agent, create incident
- Resolution: user acknowledges → resume agent, reset accumulator or increase limit

### 3.5 Spawn Endpoints
```
POST   /api/v1/spawn                     # Launch temporary agent instance
GET    /api/v1/spawn/active              # List running spawned agents
DELETE /api/v1/spawn/:id                 # Kill instance
GET    /api/v1/spawn/history             # Past spawn results
```

---

## Phase 4: Work Management (Week 4-5)

### 4.1 Issue Endpoints
```
GET    /api/v1/issues                    # List with filter (project, goal, status, assignee)
POST   /api/v1/issues
GET    /api/v1/issues/:id                # Includes comments, work_products
PATCH  /api/v1/issues/:id
DELETE /api/v1/issues/:id
POST   /api/v1/issues/:id/assign         # Assign to agent → triggers wake
POST   /api/v1/issues/:id/comments
GET    /api/v1/issues/:id/comments
POST   /api/v1/issues/:id/checkout       # Atomic checkout (prevents double-work)
```

### 4.2 Goal Endpoints
```
GET    /api/v1/goals                     # Flat list or tree
POST   /api/v1/goals
GET    /api/v1/goals/:id                 # With linked issues, cost
PATCH  /api/v1/goals/:id
DELETE /api/v1/goals/:id
GET    /api/v1/goals/:id/ancestry        # Full chain: issue → goal → project → mission
```

### 4.3 Project Endpoints
```
GET    /api/v1/projects
POST   /api/v1/projects
GET    /api/v1/projects/:id              # With goals, workspaces
PATCH  /api/v1/projects/:id
DELETE /api/v1/projects/:id
GET    /api/v1/projects/:id/goals
GET    /api/v1/projects/:id/workspaces
```

### 4.4 Document Endpoints
```
GET    /api/v1/documents                 # File tree of .canopy/reference/
GET    /api/v1/documents/*path           # Get document content
PUT    /api/v1/documents/*path           # Save document
DELETE /api/v1/documents/*path
POST   /api/v1/documents                 # Create new document
```

### 4.5 Inbox Endpoints
```
GET    /api/v1/inbox                     # List notifications (filter: type, agent, priority, read)
POST   /api/v1/inbox/:id/read           # Mark as read
POST   /api/v1/inbox/read-all           # Mark all read
POST   /api/v1/inbox/:id/action          # Execute action (approve, reject, acknowledge, snooze)
```

---

## Phase 5: Real-Time + Observability (Week 5-6)

### 5.1 SSE Streams (3 endpoints)
```
GET /api/v1/activity/stream              # Live event feed (all activity_events)
GET /api/v1/logs/stream                  # Real-time log streaming (filtered by level/source)
GET /api/v1/sessions/:id/stream          # Session execution stream (tool calls, reasoning, output)
```

**Implementation**: Phoenix controller that holds the connection open, subscribes to PubSub topic, sends `text/event-stream` data. Each SSE event is:
```
event: <event_type>
data: <json_payload>

```

### 5.2 WebSocket (1 endpoint)
```
ws://localhost:9089/ws
```

Phoenix Channel for bidirectional communication:
- `chat:*` — send messages, receive streaming responses
- `inspector:*` — real-time execution state for inspector panel
- `presence:*` — agent online/offline status

### 5.3 Event Types (full union — from spec Section 13)
```elixir
# Agent lifecycle
"agent.status_changed"      # idle → working → error
"agent.heartbeat_started"   # heartbeat run began
"agent.heartbeat_completed" # heartbeat run finished
"agent.hired"               # new agent added
"agent.terminated"          # agent removed
"agent.paused"
"agent.resumed"

# Execution
"run.started"
"run.tool_call"             # tool invocation
"run.tool_result"           # tool response
"run.thinking"              # reasoning step
"run.output"                # text output chunk
"run.completed"
"run.failed"
"run.cancelled"

# Work
"issue.created"
"issue.assigned"
"issue.status_changed"
"issue.commented"
"goal.progress_updated"
"project.updated"

# Budget
"budget.warning"            # threshold hit
"budget.hard_stop"          # limit exceeded, agent paused
"budget.incident_resolved"

# System
"gateway.connected"
"gateway.disconnected"
"config.changed"
"workspace.activated"
"alert.triggered"
"webhook.received"
"user.logged_in"
```

### 5.4 Activity + Log Endpoints
```
GET    /api/v1/activity                  # Paginated activity history
GET    /api/v1/activity/stream           # SSE
GET    /api/v1/logs/stream               # SSE (filter via query params: level, source, session_id)
```

### 5.5 Memory Endpoints
```
GET    /api/v1/memory                    # List (filter: agent_id, category, tags)
POST   /api/v1/memory
GET    /api/v1/memory/:id
PATCH  /api/v1/memory/:id
DELETE /api/v1/memory/:id
GET    /api/v1/memory/search?q=          # Full-text search
```

### 5.6 Signal Endpoints
```
POST   /api/v1/signals/classify          # Classify message: S=(M,G,T,F,W)
GET    /api/v1/signals/feed              # Signal analysis feed
GET    /api/v1/signals/patterns          # Pattern detection results
GET    /api/v1/signals/stats             # Type/channel/mode distribution
```

---

## Phase 6: Automation (Week 6-7)

### 6.1 Skill Endpoints
```
GET    /api/v1/skills                    # List (filter: category, enabled)
GET    /api/v1/skills/:id
POST   /api/v1/skills/:id/toggle         # Enable/disable
POST   /api/v1/skills/bulk-enable
POST   /api/v1/skills/bulk-disable
GET    /api/v1/skills/categories
POST   /api/v1/skills/import             # Import from URL/file content
POST   /api/v1/skills/:id/inject         # Runtime inject to running agent
```

### 6.2 Webhook Endpoints
```
GET    /api/v1/webhooks
POST   /api/v1/webhooks
GET    /api/v1/webhooks/:id
PATCH  /api/v1/webhooks/:id
DELETE /api/v1/webhooks/:id
POST   /api/v1/webhooks/:id/test         # Send test payload
GET    /api/v1/webhooks/:id/deliveries   # Delivery log

# Incoming webhook receiver:
POST   /api/v1/hooks/:webhook_id         # External services POST here
```

### 6.3 Alert Endpoints
```
GET    /api/v1/alerts/rules
POST   /api/v1/alerts/rules
GET    /api/v1/alerts/rules/:id
PATCH  /api/v1/alerts/rules/:id
DELETE /api/v1/alerts/rules/:id
POST   /api/v1/alerts/evaluate           # Evaluate all rules now
GET    /api/v1/alerts/history
```

### 6.4 Integration Endpoints
```
GET    /api/v1/integrations              # List all (grouped by category)
POST   /api/v1/integrations/:slug/connect  # Connect with config
DELETE /api/v1/integrations/:slug        # Disconnect
GET    /api/v1/integrations/:slug/status # Check connection status
POST   /api/v1/integrations/pull-all     # Refresh all connection statuses
```

---

## Phase 7: Adapter System (Week 7-8)

### 7.1 Adapter Interface (Elixir Behaviour)
```elixir
defmodule Canopy.Adapter do
  @callback type() :: String.t()
  @callback name() :: String.t()
  @callback start(config :: map()) :: {:ok, session :: map()} | {:error, term()}
  @callback stop(session :: map()) :: :ok | {:error, term()}
  @callback execute_heartbeat(params :: map()) :: Enumerable.t()  # Stream of events
  @callback send_message(session :: map(), message :: String.t()) :: Enumerable.t()
  @callback supports_session?() :: boolean()
  @callback supports_concurrent?() :: boolean()
  @callback capabilities() :: [atom()]
end
```

### 7.2 Adapters to Implement

| Adapter | Priority | Method |
|---------|----------|--------|
| **OSA** | P0 | Elixir GenServer — direct function calls to existing OSA |
| **Claude Code** | P0 | Spawn `claude` CLI process, parse stdout, manage context |
| **Codex** | P1 | Spawn `codex` CLI process |
| **Bash** | P1 | Spawn shell, capture output |
| **HTTP** | P1 | POST task → poll for result |
| **OpenClaw** | P2 | WebSocket to OpenClaw gateway |
| **Cursor** | P2 | Cursor background agent protocol |
| **Gemini** | P2 | Gemini CLI |

### 7.3 Execution Workspace
Each heartbeat run gets an isolated workspace:
- **Git worktree** (default): `git worktree add` in project dir, clean up after
- **Docker**: spawn container with project mounted
- **Sandbox**: restricted filesystem access
- **Shared**: run in main workspace (no isolation)

---

## Phase 8: Admin (Week 8-9)

### 8.1 Admin Endpoints
```
GET    /api/v1/users
POST   /api/v1/users
PATCH  /api/v1/users/:id
DELETE /api/v1/users/:id
GET    /api/v1/audit                     # Immutable audit trail (filter: action, actor, time)
GET    /api/v1/gateways
POST   /api/v1/gateways
DELETE /api/v1/gateways/:id
POST   /api/v1/gateways/:id/probe        # Test connection
GET    /api/v1/config                    # System configuration
PATCH  /api/v1/config                    # Update configuration
GET    /api/v1/templates
POST   /api/v1/templates
```

### 8.2 Audit Trail
Every significant action logged to `audit_events` table. Immutable — no UPDATE or DELETE on this table. Insertions happen via a Plug that wraps controllers.

---

## Phase 9: Integration Testing (Week 9-10)

### 9.1 Verify All Endpoints
- All ~80 REST endpoints return correct JSON matching TypeScript types
- SSE streams deliver events in correct format
- WebSocket channels handle chat + inspector correctly

### 9.2 End-to-End Flows
- **Heartbeat**: create schedule → cron fires → adapter executes → events stream → session recorded → cost tracked
- **Budget**: set policy → accumulate cost → warning at threshold → hard stop → resolve
- **Issue assignment**: assign to agent → wake agent → heartbeat checks issues → picks up work → completes → updates status

### 9.3 Performance
- API response times <100ms for CRUD, <500ms for aggregations
- SSE event delivery <50ms from PubSub publish
- Concurrent heartbeats: support 10+ simultaneous agent runs

---

## Supervision Tree

```
Canopy.Application
├── Canopy.Repo                          # Ecto PostgreSQL
├── CanopyWeb.Endpoint                   # Phoenix HTTP/WS
├── Canopy.EventBus                      # PubSub for SSE/WS broadcast
├── Canopy.Scheduler                     # Quantum cron jobs
├── Canopy.BudgetEnforcer                # GenServer tracking cost accumulation
├── Canopy.AdapterSupervisor             # DynamicSupervisor for adapter processes
│   ├── Canopy.Adapter.OSA
│   ├── Canopy.Adapter.ClaudeCode
│   └── ...
├── Canopy.HeartbeatRunner               # Task.Supervisor for heartbeat execution
└── Canopy.AlertEvaluator                # Periodic alert rule evaluation
```

---

## Summary

| Phase | Focus | Key Deliverables |
|-------|-------|-----------------|
| 1 | Foundation | Project setup, DB schema, health + dashboard endpoints, auth |
| 2 | Core CRUD | Workspace, Agent, Session endpoints + chat SSE |
| 3 | Scheduling | Schedule CRUD, Quantum heartbeat, Budget engine, Spawn |
| 4 | Work Mgmt | Issues, Goals, Projects, Documents, Inbox endpoints |
| 5 | Real-Time | SSE streams, WebSocket, Activity/Logs, Memory, Signals |
| 6 | Automation | Skills, Webhooks, Alerts, Integrations endpoints |
| 7 | Adapters | Adapter behaviour, OSA + Claude Code + Bash + HTTP adapters |
| 8 | Admin | Users/RBAC, Audit trail, Gateways, Config, Templates |
| 9 | Testing | E2E heartbeat flow, budget enforcement, performance |

**Total**: ~80 REST endpoints, 3 SSE streams, 1 WebSocket, 8 adapters, ~20 DB tables
