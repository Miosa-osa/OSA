# Canopy Command Center — Complete Specification

> The desktop application for orchestrating proactive autonomous AI agent systems.
> Built with SvelteKit + Tauri. Part of the MIOSA ecosystem.

**Version:** 1.0-draft
**Date:** 2026-03-20
**Author:** Roberto H Luna / OSA Agent

---

## Table of Contents

1. [Vision](#1-vision)
2. [Architecture](#2-architecture)
3. [Tech Stack](#3-tech-stack)
4. [Workspace Protocol](#4-workspace-protocol-canopy)
5. [Sidebar Navigation](#5-sidebar-navigation)
6. [Pages — Complete Specification](#6-pages--complete-specification)
7. [Floating Panels](#7-floating-panels)
8. [Route Map](#8-route-map)
9. [Component Architecture](#9-component-architecture)
10. [Store Architecture](#10-store-architecture)
11. [Adapter System](#11-adapter-system)
12. [Backend API Surface](#12-backend-api-surface)
13. [Real-Time Communication](#13-real-time-communication)
14. [Design System](#14-design-system)
15. [Keyboard Shortcuts](#15-keyboard-shortcuts)
16. [Reference Apps](#16-reference-apps)
17. [Implementation Phases](#17-implementation-phases)

---

## 1. Vision

The Canopy Command Center is the desktop UI for orchestrating AI agent teams. It is not a chatbot interface, not a prompt manager, and not a single-agent tool. It is the **operations center** for running multiple AI agents that work proactively, autonomously, and collaboratively toward business outcomes.

### Core Metaphor

- **Canopy** = The workspace/office. A `.canopy/` directory defines agents, skills, projects, and knowledge for a workspace. The frontend renders this workspace visually.
- **Command Center** = The application itself. The CEO's operations room for supervising, directing, and monitoring their AI team.
- **Agents = Employees**. You hire them, assign them work, set their schedules, monitor their performance, enforce their budgets, and terminate them when needed.

### What It Does

1. **Orchestrates** — Manages multiple agents across multiple workspaces with different adapters (OSA, Claude Code, Codex, OpenClaw, Bash, HTTP)
2. **Proactive** — Agents wake on heartbeat schedules, check for assigned work, execute autonomously, report back
3. **Observable** — Every action is logged, every token counted, every cost tracked, every execution auditable
4. **Governed** — Approval gates, budget enforcement, role-based access, immutable audit trails
5. **Visual** — 2D/3D Virtual Office showing agents at work, org charts, goal hierarchies, cost dashboards

### What It Is NOT

- Not a chatbot UI (chat is a side panel, not the main experience)
- Not a code editor (use your editor; this manages the agents that edit code)
- Not a workflow builder (agents self-organize; you set goals and constraints)
- Not a single-agent tool (multi-agent orchestration is the core)

---

## 2. Architecture

### System Overview

```
┌─────────────────────────────────────────────────────┐
│                  Canopy Command Center               │
│               (SvelteKit + Tauri Desktop)             │
│                                                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │ Sidebar  │  │ Page     │  │ Floating │           │
│  │ Nav      │  │ Content  │  │ Panels   │           │
│  └──────────┘  └──────────┘  └──────────┘           │
│        │              │              │                │
│  ┌─────────────────────────────────────────┐         │
│  │           Svelte 5 Stores ($state)      │         │
│  └─────────────────────────────────────────┘         │
│        │              │              │                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │ REST API │  │ SSE      │  │ WebSocket│           │
│  │ Client   │  │ Stream   │  │ Client   │           │
│  └──────────┘  └──────────┘  └──────────┘           │
└────────┬──────────────┬──────────────┬───────────────┘
         │              │              │
    ┌────▼──────────────▼──────────────▼────┐
    │         Backend (Adapter Layer)        │
    │                                        │
    │  ┌─────────────────────────────────┐  │
    │  │     Gateway / API Server         │  │
    │  └─────────────────────────────────┘  │
    │        │         │         │          │
    │  ┌─────▼──┐ ┌────▼───┐ ┌──▼─────┐   │
    │  │  OSA   │ │ Claude │ │ Codex  │   │
    │  │Elixir  │ │ Code   │ │        │   │
    │  └────────┘ └────────┘ └────────┘   │
    │  ┌────────┐ ┌────────┐ ┌────────┐   │
    │  │OpenClaw│ │ Cursor │ │  Bash  │   │
    │  └────────┘ └────────┘ └────────┘   │
    │  ┌────────┐                          │
    │  │  HTTP  │  (Generic heartbeat)     │
    │  └────────┘                          │
    └──────────────────────────────────────┘
         │
    ┌────▼──────────────────────────────────┐
    │         .canopy/ Workspace             │
    │  (Filesystem — the source of truth)    │
    └───────────────────────────────────────┘
```

### Data Flow

1. **Workspace Discovery**: Tauri Rust backend scans `.canopy/` directories → populates stores
2. **Agent Execution**: Heartbeat scheduler wakes agent → adapter spawns process → streams output via SSE
3. **Real-Time Updates**: SSE/WebSocket events → store updates → reactive UI re-render
4. **User Actions**: UI interaction → REST API call → backend processes → event broadcast → UI updates

### Repository Structure

```
canopy/
├── desktop/                    SvelteKit + Tauri application
│   ├── src/
│   │   ├── lib/
│   │   │   ├── components/     UI components (Foundation styling)
│   │   │   ├── stores/         Svelte 5 runes stores
│   │   │   ├── api/            REST + SSE + WebSocket clients
│   │   │   └── utils/          Shared utilities
│   │   ├── routes/
│   │   │   ├── app/            All application routes (32 pages)
│   │   │   └── onboarding/     First-run setup
│   │   └── app.html
│   ├── src-tauri/              Rust backend
│   │   ├── src/
│   │   │   ├── commands/       Tauri IPC commands
│   │   │   ├── filesystem/     .canopy/ scanner + watcher
│   │   │   ├── shell/          Terminal + process management
│   │   │   └── main.rs
│   │   └── Cargo.toml
│   ├── static/
│   ├── package.json
│   ├── svelte.config.js
│   └── vite.config.ts
│
├── protocol/                   Canopy Workspace Protocol
│   ├── SPEC.md                 Formal specification
│   ├── discovery.ts            Agent/skill/project discovery engine
│   ├── templates/              Default workspace templates
│   │   ├── SYSTEM.md.template
│   │   ├── COMPANY.md.template
│   │   └── agent.md.template
│   └── schemas/                JSON schemas for config files
│
├── adapters/                   Agent runtime adapters
│   ├── osa/                    OSA Elixir/OTP (primary)
│   ├── claude-code/            Claude Code CLI
│   ├── codex/                  Codex CLI
│   ├── openclaw/               OpenClaw gateway
│   ├── cursor/                 Cursor editor
│   ├── gemini/                 Gemini CLI
│   ├── bash/                   Raw shell execution
│   └── http/                   Generic HTTP heartbeat
│
├── skills/                     Shared skill library
│   ├── registry/               Skill registry + discovery
│   └── builtins/               Built-in skills
│
├── templates/                  Workspace + team templates
│   ├── engineering-team/       Full-stack dev team preset
│   ├── research-team/          Research & analysis preset
│   ├── content-team/           Content creation preset
│   └── custom/                 User-created templates
│
└── docs/                       Documentation
```

---

## 3. Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| **Desktop Runtime** | Tauri 2.x | 10MB binary, 30MB RAM, native Rust backend, filesystem/shell access, IPC bridge |
| **Frontend Framework** | SvelteKit 2 + Svelte 5 | Runes reactivity ($state/$derived), no virtual DOM, less boilerplate than React |
| **State Management** | Svelte 5 runes (class-based stores) | Native to framework, no extra library needed |
| **Styling** | Foundation Design System CSS + Tailwind CSS 4 | Glassmorphic dark-mode components, CSS custom properties |
| **3D Rendering** | Threlte (Three.js for Svelte) | Official Svelte Three.js binding, production-ready |
| **2D Graphics** | SVG + CSS animations | Lightweight, no extra dependencies |
| **Charts** | Layerchart (Svelte-native) or Chart.js | Cost dashboards, token usage, activity heatmaps |
| **Terminal** | xterm.js | Battle-tested terminal emulator |
| **Code Editor** | Monaco Editor (via Svelte wrapper) | File browser inline editing |
| **Org Chart / Flow** | Svelvet (Svelte Flow) | Node-based graph visualization |
| **Markdown** | marked + highlight.js | Document rendering |
| **HTTP Client** | fetch (native) | REST API calls |
| **Real-Time** | EventSource (SSE) + WebSocket | Live streaming from backend |
| **Persistence** | Tauri Store plugin | Local preferences, workspace state |
| **Testing** | Vitest + Testing Library | Unit + component tests |
| **Build** | Vite 6 | Fast dev server, optimized production builds |

### Why NOT Electron / React

| Factor | Tauri + Svelte | Electron + React |
|--------|---------------|-----------------|
| Binary size | ~10MB | ~150MB |
| RAM at idle | ~30MB | ~150MB+ |
| Startup time | <1s | 2-5s |
| Filesystem access | Native Rust (fast, secure) | Node.js (slower, more attack surface) |
| Reactivity model | Runes (compile-time) | Hooks (runtime, re-render overhead) |
| Bundle size | ~50KB framework | ~130KB React + ReactDOM |
| Our existing work | 94 Svelte components to port patterns from | Would require full rewrite |

---

## 4. Workspace Protocol (.canopy/)

The `.canopy/` directory is the source of truth for a workspace. The Command Center renders it visually.

### Directory Structure

```
project-root/
└── .canopy/
    ├── SYSTEM.md              Workspace identity + boot configuration
    ├── COMPANY.md             Org structure, governance rules, mission
    │
    ├── agents/                Agent definitions (one .md per agent)
    │   ├── orchestrator.md    YAML frontmatter + system prompt
    │   ├── research-agent.md
    │   ├── code-worker.md
    │   └── security-auditor.md
    │
    ├── skills/                Executable skills
    │   ├── code-review.md     Skill definition + trigger rules
    │   ├── test-runner.md
    │   └── deploy.md
    │
    ├── projects/              Project definitions
    │   ├── alpha/
    │   │   ├── README.md      Project description + goals
    │   │   ├── goals.yaml     Goal hierarchy
    │   │   └── issues/        Project-scoped issues
    │   └── beta/
    │
    ├── schedules/             Heartbeat configurations
    │   ├── morning-standup.yaml    Cron: "0 9 * * 1-5"
    │   ├── continuous-review.yaml  Cron: "*/30 * * * *"
    │   └── nightly-tests.yaml     Cron: "0 2 * * *"
    │
    ├── reference/             Domain knowledge documents
    │   ├── architecture.md
    │   ├── api-spec.md
    │   └── style-guide.md
    │
    ├── memory/                Persistent agent memory
    │   ├── shared/            Shared across all agents
    │   └── per-agent/         Agent-specific memories
    │       ├── orchestrator/
    │       └── research-agent/
    │
    ├── integrations/          Connected service configs
    │   ├── providers.yaml     AI provider API keys (encrypted)
    │   ├── github.yaml        GitHub integration config
    │   └── slack.yaml         Slack webhook config
    │
    ├── templates/             Local workspace templates
    │
    ├── webhooks/              Webhook configurations
    │   └── on-pr-opened.yaml
    │
    ├── alerts/                Alert rule definitions
    │   └── budget-warning.yaml
    │
    └── config/                Workspace configuration
        ├── settings.yaml      General settings
        ├── budgets.yaml       Per-agent budget policies
        └── permissions.yaml   Access control rules
```

### Agent Definition Format (.canopy/agents/*.md)

```yaml
---
name: Research Agent
role: researcher
reports_to: orchestrator
adapter: claude-code
model: claude-sonnet-4-6
temperature: 0.3
max_concurrent_runs: 2
budget:
  monthly_limit_usd: 50.00
  warning_threshold_pct: 80
  hard_stop: true
schedule:
  cron: "*/30 * * * *"
  context: "Check for new research tasks in assigned issues"
skills:
  - web-search
  - document-analysis
  - summarization
tools:
  - read_file
  - write_file
  - web_fetch
  - knowledge_query
workspace_strategy: worktree
status: active
---

# Research Agent

You are a research specialist. Your job is to investigate topics assigned to you,
synthesize findings, and produce clear research reports.

## Responsibilities
- Monitor assigned issues for research requests
- Conduct thorough web research using available tools
- Produce structured research reports in markdown
- Collaborate with the orchestrator on complex investigations

## Reporting
Report findings to the orchestrator. If a task requires code changes,
delegate to the Code Worker via the orchestrator.
```

### Schedule Definition Format (.canopy/schedules/*.yaml)

```yaml
name: Morning Standup
description: Wake all agents to check for overnight issues and plan the day
cron: "0 9 * * 1-5"
timezone: America/New_York
agents:
  - orchestrator
  - research-agent
  - code-worker
context: |
  It's morning standup. Review:
  1. Any new issues assigned overnight
  2. Status of in-progress work
  3. Any failed runs from last night
  4. Plan today's priorities
enabled: true
last_run: 2026-03-19T14:00:00Z
next_run: 2026-03-20T14:00:00Z
```

### Sidebar ↔ Workspace Mapping

Every sidebar section maps 1:1 to what's in `.canopy/`:

| Sidebar Section | .canopy/ Source | What It Renders |
|---|---|---|
| TEAM (dynamic) | `agents/*.md` | Agent list with status dots |
| PROJECTS (dynamic) | `projects/*/` | Project list from directories |
| OPS > Issues | `projects/*/issues/` | Issues across all projects |
| OPS > Goals | `projects/*/goals.yaml` | Goal hierarchy |
| OPS > Documents | `reference/` | Workspace documentation |
| ORCHESTRATE > Skills | `skills/*.md` | Skill marketplace |
| ORCHESTRATE > Schedules | `schedules/*.yaml` | Heartbeat configurations |
| ORCHESTRATE > Webhooks | `webhooks/*.yaml` | Webhook configs |
| ORCHESTRATE > Alerts | `alerts/*.yaml` | Alert rules |
| ORCHESTRATE > Integrations | `integrations/*.yaml` | Connected services |
| MONITOR > Memory | `memory/` | Knowledge base |
| ADMIN > Config | `config/` | System configuration |
| ADMIN > Templates | `templates/` | Workspace templates |

---

## 5. Sidebar Navigation

### Design Principles

1. **The sidebar IS the workspace** — every section maps to `.canopy/`
2. **Collapsible sections** — 9 items visible when collapsed, full power when expanded
3. **Dynamic lists** — PROJECTS and TEAM sections show actual workspace content
4. **Live status** — Agent status dots, badge counts, connection indicators
5. **Chat is a panel, not a page** — accessible via ⌘/ from anywhere
6. **Command Center language** — "Hire Agent" not "Create Agent", "Routines" not "Cron"

### Complete Sidebar Structure

```
┌──────────────────────────────────────┐
│ ◈ CANOPY                           ▼│  Workspace/Company switcher
│   acme-corp · 🟢 4 agents online     │  Live status line
│──────────────────────────────────────│
│ 🔍 Search...                   ⌘K   │  Command palette (global search)
│ ✏  New Issue                         │  Quick action button
├──────────────────────────────────────┤
│                                      │
│   Dashboard                    ⌘1    │  Overview + KPIs + live runs
│   Inbox                    (3) ⌘2    │  Approvals + alerts + mentions
│   Office                       ⌘3    │  2D/3D Virtual Office
│                                      │
│ OPS ────────────────────── ▾        │  The work being done
│   Issues                             │  Ticket tracker + kanban
│   Goals                              │  Strategic hierarchy
│   Documents                          │  Workspace knowledge base
│                                      │
│ PROJECTS ──────────────── ▾  (3)    │  Dynamic from .canopy/projects/
│   ▪ Project Alpha                    │
│   ▪ Project Beta                     │
│   ▪ Project Gamma                    │
│   + New Project                      │
│                                      │
│ TEAM ─────────────────── ▾ 🟢(4)   │  Dynamic from .canopy/agents/
│   🟢 Orchestrator          working   │  Live status + time
│   🟡 Research Agent        idle 12m  │
│   ⚪ Code Worker           sleeping  │
│   ⚪ Security Auditor      offline   │
│   + Hire Agent                       │
│                                      │
│ MONITOR ───────────────── ▾         │  Observability layer
│   Activity                           │  Live event feed
│   Sessions                           │  Active runs + token bars
│   Logs                               │  Real-time log stream
│   Costs                              │  Finance + budget enforcement
│   Memory                             │  Knowledge base browser
│   Signals                            │  Signal Theory analysis
│                                      │
│ ORCHESTRATE ───────────── ▾         │  Proactive automation
│   Skills                             │  Capability marketplace
│   Schedules                          │  Heartbeats + timers
│   Spawn                              │  Launch agent instances
│   Webhooks                           │  External triggers
│   Alerts                             │  Notification rules
│   Integrations                       │  Providers + services
│                                      │
│ ADMIN ─────────────────── ▾         │  System management
│   Users                              │  Team + roles + RBAC
│   Audit                              │  Immutable event trail
│   Gateways                           │  Connection infrastructure
│   Config                             │  System config editor
│   Templates                          │  Workspace + team presets
│   Workspaces                         │  Multi-workspace admin
│                                      │
├──────────────────────────────────────┤
│ >_ Terminal                    ⌘T    │  Always accessible
│ ⚙  Settings                   ⌘,    │  App preferences
│──────────────────────────────────────│
│ [●] Roberto Luna                ▸   │  User profile + role
│     admin · online                   │
└──────────────────────────────────────┘
```

### Collapsed State (Default View)

When all sections are collapsed, the user sees:

```
◈ CANOPY ▼  acme-corp · 🟢 4
🔍 Search...                   ⌘K

  Dashboard                    ⌘1
  Inbox                    (3) ⌘2
  Office                       ⌘3
▸ OPS                      (12)
▸ PROJECTS                  (3)
▸ TEAM                   🟢 (4)
▸ MONITOR
▸ ORCHESTRATE
▸ ADMIN

>_ Terminal                    ⌘T
⚙  Settings                   ⌘,
[●] Roberto Luna
```

**9 visible items + 6 collapsed headers. Clean but comprehensive.**

### Section Behaviors

| Section | Collapsed Shows | Expanded Shows | Badge/Indicator |
|---|---|---|---|
| OPS | Item count (open issues + goals) | Issues, Goals, Documents | Count in parentheses |
| PROJECTS | Project count | Dynamic project list + "New" | Count in parentheses |
| TEAM | Agent count + status dot | Dynamic agent list with status | Green dot if any active |
| MONITOR | Nothing extra | Activity, Sessions, Logs, Costs, Memory, Signals | — |
| ORCHESTRATE | Nothing extra | Skills, Schedules, Spawn, Webhooks, Alerts, Integrations | — |
| ADMIN | Nothing extra | Users, Audit, Gateways, Config, Templates, Workspaces | — |

### Naming Decisions

| Concept | Bad Names (Avoided) | Chosen Name | Why |
|---|---|---|---|
| Recurring agent tasks | Cron, Scheduled Tasks | **Schedules** | Users schedule things. Plain English. |
| External services | Connectors, Providers | **Integrations** | Industry standard. Broad enough for all service types. |
| Agent list | Intelligence, Agents section | **TEAM** | Agents are your team members. |
| The work | Work, Tasks | **OPS** | Operations. What the team is working on. |
| Monitoring | Observe, System | **MONITOR** | Direct, no ambiguity. |
| Automation section | Automate, System | **ORCHESTRATE** | This IS the orchestration system. |
| Creating an agent | New Agent, Create Agent | **Hire Agent** | Business metaphor. You hire employees. |
| Token tracking | Usage | **Costs** | What it actually shows — money. |
| Notifications | Approvals | **Inbox** | Unified. One place for everything. |
| Recurring jobs | Cron, Routines | **Schedules** | Heartbeat patterns, timed execution. |

---

## 6. Pages — Complete Specification

### 6.1 Dashboard (`/app`)

The CEO's morning briefing. Everything important at a glance.

**Layout:**
```
┌─────────────────────────────────────────────────┐
│ Dashboard                           ⌘1          │
├──────────┬──────────┬──────────┬────────────────┤
│ Active   │ Live     │ Open     │ Budget         │
│ Agents   │ Runs     │ Issues   │ Remaining      │
│    4     │    2     │   12     │  $847/$1000    │
├──────────┴──────────┴──────────┴────────────────┤
│                                                  │
│ Live Runs                              View All  │
│ ┌──────────────────────────────────────────────┐│
│ │ 🟢 Orchestrator reviewing PR #142     2m 13s ││
│ │ 🟢 Code Worker implementing issue #89 4m 02s ││
│ └──────────────────────────────────────────────┘│
│                                                  │
│ Recent Activity                        View All  │
│ ┌──────────────────────────────────────────────┐│
│ │ Orchestrator completed heartbeat run    2m ago││
│ │ Research Agent marked issue #87 done    5m ago││
│ │ Budget warning: Code Worker at 82%     12m ago││
│ └──────────────────────────────────────────────┘│
│                                                  │
│ Finance Summary                                  │
│ ┌────────────┬─────────────┬───────────────────┐│
│ │ Today: $12 │ Week: $84   │ Month: $153       ││
│ │ Top: Code  │ Top: Code   │ Budget: 85% left  ││
│ └────────────┴─────────────┴───────────────────┘│
│                                                  │
│ Quick Actions                                    │
│ [New Issue] [Wake All] [Spawn Agent] [View Org]  │
└──────────────────────────────────────────────────┘
```

**Data Sources:**
- Active agents: SessionRegistry / adapter heartbeat status
- Live runs: SSE stream of active heartbeat executions
- Open issues: Issue store aggregate
- Budget: Budget policy service
- Finance: Finance ledger service
- Activity: Event bus (last 10 events)

### 6.2 Inbox (`/app/inbox`)

Unified notification center. Replaces standalone Approvals page.

**Content:**
- Approval requests (hire agent, budget override, destructive actions)
- Budget incidents (warning threshold hit, hard stop triggered)
- Alert triggers (rules that fired)
- Agent mentions (agent-to-user messages)
- Failed runs (heartbeat failures, adapter errors)
- Hire requests (agents requesting to join from external adapters)

**Features:**
- Filter by: type, agent, priority, read/unread
- Inline actions: Approve/Reject, Acknowledge, Assign, Snooze
- Mark all read
- Badge count synced to sidebar

### 6.3 Office (`/app/office`)

The Virtual Office — Canopy made visual. Where you SEE your agents working.

**2D Mode (Default):**
- SVG isometric floor plan with desk zones
- Agent avatars at desks with deterministic generation
- Real-time status animations:
  - Idle: subtle breathing
  - Working: active typing animation
  - Speaking: speech bubble with current output (markdown streaming)
  - Tool calling: tool icon pulse
  - Error: red glow
- Collaboration lines between communicating agents
- Speech bubbles showing live activity
- Click agent → slide-out detail panel

**3D Mode:**
- Three.js via Threlte (Svelte Three.js binding)
- Character models at workstations
- Holographic skill displays above agents
- Spawn portals (visual effect when agent spawns)
- Camera controls: orbit, pan, zoom
- Post-processing effects (bloom, ambient occlusion)

**Toggle:** 2D ⟷ 3D button in header

**Side Panel (on agent click):**
- Agent name + status
- Current task description
- Last heartbeat time + next scheduled
- Token usage chart (line graph, last 24h)
- Cost pie chart (this agent vs total)
- Sub-agent relationship graph (if orchestrator)
- Event timeline (recent actions)
- Quick actions: Wake, Sleep, Focus, Chat

### 6.4 Issues (`/app/issues`)

Ticket-based work management. The primary way work gets assigned to agents.

**Views:**
- **List**: Sortable table with status, priority, assignee, project, goal
- **Kanban**: Drag-and-drop columns (Backlog, Todo, In Progress, In Review, Done)
- **Table**: Spreadsheet-style with inline editing

**Issue Detail (`/app/issues/[id]`):**
- Title + description (markdown)
- Properties panel: status, priority, assignee (agent), project, goal ancestry
- Comment thread (human + agent comments)
- Execution workspace link (where agent is working on this)
- Work products (PRs, files, commits produced)
- Run transcript link (what the agent did)
- Activity timeline (status changes, assignments)

**Features:**
- Quick assign to agent → triggers heartbeat wake-up
- "My Issues" filtered view (issues assigned to current user's agents)
- Goal ancestry trace (issue → goal → project → mission)
- Checkout mechanism (atomic assignment, prevents double-work)

### 6.5 Goals (`/app/goals`)

Strategic hierarchy. Traces from company mission down to individual tasks.

**Visualization:**
- Tree view: Mission → Project → Goal → Sub-goal → Issue
- Each node: title, progress bar (based on child completion), assigned agents, budget allocation
- Drag to restructure hierarchy
- Expand/collapse branches

**Goal Detail (`/app/goals/[id]`):**
- Properties: status, owner (agent), parent goal, project
- Linked issues (what work is being done for this goal)
- Cost tracking (how much has been spent on this goal)
- Progress metrics (issues closed / total)

### 6.6 Documents (`/app/documents`)

Workspace document browser. Renders `.canopy/reference/` and other workspace files.

**Layout:**
- Left panel: File tree browser (`.canopy/reference/`, SYSTEM.md, COMPANY.md, agent definitions)
- Right panel: Document viewer (markdown rendered) or Monaco editor (edit mode)
- Search across all documents
- Create new document
- Edit in-place with save

### 6.7 Agent Roster (`/app/agents`)

The team roster. All agents in the workspace.

**Views:**
- **Grid**: Cards with avatar, name, role, status, model, budget bar
- **Org Chart**: Visual hierarchy (Svelvet graph) showing reporting lines
- **Table**: Sortable list view

**Agent Detail (`/app/agents/[id]`):**

Seven tabs:

| Tab | Content |
|---|---|
| **Overview** | Status, current task, last heartbeat, recent activity, token usage chart, cost breakdown |
| **Config** | Model, temperature, tools, adapter type, max concurrent runs, workspace strategy, system prompt editor |
| **Schedules** | This agent's heartbeat schedule(s), wake-up patterns, next run, cron editor |
| **Skills** | Skills assigned to this agent, toggle on/off, inject new skill at runtime |
| **Runs** | Execution history — each run: start/end time, tokens, cost, workspace, work products, transcript link |
| **Budget** | Budget policy (monthly limit, warning %, hard stop), spend vs limit chart, incidents log |
| **Inbox** | Messages TO this agent from other agents (inter-agent communication visible) |

**Actions (in header):**
- Wake (trigger immediate heartbeat)
- Sleep (disable scheduling)
- Focus Mode (block all tasks except current)
- Pause (temporary stop, preserves state)
- Terminate (permanent removal)
- Edit Config (quick model/settings change)
- Chat (opens chat panel focused on this agent)

### 6.8 Activity (`/app/activity`)

Live event feed. Everything happening in the workspace.

**Content:**
- Agent status changes (offline → idle → working → error)
- Heartbeat starts/completions
- Issue assignments and status changes
- Approval events
- Budget alerts and incidents
- System events (gateway connect/disconnect, config changes)

**Features:**
- SSE streaming (real-time updates)
- Filters: event type, agent, time range
- "Show details" expansion per event
- Pause/resume stream
- Export event log

**Floating Mini-Widget:**
- Small persistent indicator in bottom-right of ALL pages
- Shows last 3 events with timestamps
- Click to expand full activity overlay
- Persists across page navigation (mounted at layout level)

### 6.9 Sessions (`/app/sessions`)

Agent session management. Every execution run tracked.

**Session List:**
- Cards: agent name, model, token usage bar (e.g., 32k/200k), status (active/idle/completed), duration, cost
- Sort by: age, cost, tokens, agent
- Filter: status, agent, model

**Session Overview Sidebar:**
- Total sessions count
- Active / Idle / Completed counts
- Sub-agent count
- Cron jobs count
- Model distribution chart (opus: 12, sonnet: 3)

**Session Detail (`/app/sessions/[id]`):**
- Full execution transcript (tool calls, reasoning, outputs)
- Execution workspace info (directory, git branch, status)
- Token usage breakdown (input/output/cache)
- Work products (files created/modified, PRs opened)
- Timeline view of actions

### 6.10 Logs (`/app/logs`)

Real-time streaming log viewer.

**Layout:**
```
┌──────────────────────────────────────────────────┐
│ Log Viewer                                       │
├──────────────────────────────────────────────────┤
│ Level: [All ▼]  Source: [All ▼]  Session: [___]  │
│ Search: [_________________________]              │
│                    [Auto] [Bottom] [Clear]        │
├──────────────────────────────────────────────────┤
│ Showing 142 of 142 logs · Auto-scroll: ON        │
│──────────────────────────────────────────────────│
│ 14:02:33 INFO  orchestrator  Heartbeat started   │
│ 14:02:34 INFO  orchestrator  Checking issues...  │
│ 14:02:35 DEBUG code-worker   Tool: read_file     │
│ 14:02:36 WARN  budget        Code Worker at 82%  │
│ 14:02:37 ERROR research      Connection timeout  │
│ ...                                              │
└──────────────────────────────────────────────────┘
```

**Features:**
- SSE streaming (real-time)
- Level filter: debug, info, warn, error
- Source filter: agent name, system, gateway
- Session filter: specific session ID
- Text search within logs
- Auto-scroll with manual scroll lock
- Click log entry → jump to related session
- Clear log buffer

### 6.11 Costs (`/app/costs`)

Financial dashboard with budget enforcement.

**Sections:**
1. **Summary Cards**: Total spend (today/week/month), budget remaining, top spending agent
2. **Daily Cost Chart**: Line graph, last 30 days
3. **Per-Agent Breakdown**: Table + pie chart showing cost distribution by agent
4. **Per-Model Distribution**: Which models are costing what
5. **Budget Policy Status**: Per-agent table showing limit, spend, status (OK / Warning / Hard Stop)
6. **Budget Incidents**: Log of enforcement events (warnings, pauses, hard stops)
7. **Anomaly Detection**: Flags unusual spending spikes with alerts
8. **Trends**: Week-over-week comparison, projected monthly spend
9. **Cache Savings**: How much prompt caching is saving

**Actions:**
- Set budget policy (per agent, per project, global)
- Adjust thresholds (warning %, hard stop)
- Resolve incidents (acknowledge, increase limit, pause agent)
- Export cost report

### 6.12 Memory (`/app/memory`)

Knowledge base browser. Renders `.canopy/memory/`.

**Features:**
- Browse shared and per-agent memories
- Markdown + JSON rendering with syntax highlighting
- Search across all memory entries
- Add/edit/delete memories
- Categories and tags
- Link memories to specific agents
- Memory usage stats (total entries, per-agent counts)

### 6.13 Signals (`/app/signals`)

Signal Theory analysis. **UNIQUE TO OSA — no other platform has this.**

**Features:**
- Classify messages: S=(M,G,T,F,W) decomposition
- Signal feed with S/N quality scores
- Pattern detection across conversations
- Failure mode identification:
  - Shannon violations (routing, bandwidth, fidelity)
  - Ashby violations (genre, variety, structure)
  - Beer violations (bridge, herniation, decay)
  - Wiener violations (feedback failure)
- Channel breakdown chart
- Type breakdown chart
- Signal weight gauges
- Filter by time range, agent, signal type

### 6.14 Skills (`/app/skills`)

Capability marketplace. Browse and manage agent skills.

**Layout:**
- Grid of skill cards with: name, description, category, trigger rules, enabled/disabled toggle
- Categories: Development, Research, Communication, Analysis, Operations, Custom
- Search + category filter
- Skill detail slide-out: full description, parameters, usage stats, which agents have it
- Bulk enable/disable
- Import skill from file/URL
- Runtime injection (add skill to running agent without restart)

### 6.15 Schedules (`/app/schedules`)

**THE HEARTBEAT CENTER.** The core proactive orchestration page.

**Layout:**
```
┌──────────────────────────────────────────────────┐
│ Schedules                          + New Schedule │
├──────────────────────────────────────────────────┤
│                                                   │
│ TIMELINE VIEW                                     │
│ ┌─────────────────────────────────────────────── │
│ │     6am    9am    12pm   3pm    6pm    9pm     │
│ │ ORC ──●─────────●─────────●─────────●────      │
│ │ RES ────────●─────────●─────────●────────      │
│ │ COD ──────────────●───────────────●──────      │
│ │ SEC ────────────────────●────────────────      │
│ └─────────────────────────────────────────────── │
│                                                   │
│ SCHEDULES                                         │
│ ┌──────────────────────────────────────────────┐ │
│ │ 🟢 Morning Standup                           │ │
│ │    Agents: All · Cron: 0 9 * * 1-5           │ │
│ │    Next: Tomorrow 9:00 AM · Last: Today ✅    │ │
│ ├──────────────────────────────────────────────┤ │
│ │ 🟢 Continuous Review                         │ │
│ │    Agent: Code Worker · Cron: */30 * * * *   │ │
│ │    Next: 14:30 · Last: 14:00 ✅               │ │
│ ├──────────────────────────────────────────────┤ │
│ │ 🟡 Nightly Tests (paused — budget limit)     │ │
│ │    Agent: Security Auditor · Cron: 0 2 * * * │ │
│ │    Last: Yesterday ❌ (budget exceeded)        │ │
│ └──────────────────────────────────────────────┘ │
│                                                   │
│ WAKE-UP QUEUE                         3 pending   │
│ ┌──────────────────────────────────────────────┐ │
│ │ Orchestrator — manual wake request    Now     │ │
│ │ Research Agent — issue #92 assigned   2m ago  │ │
│ │ Code Worker — PR review needed        5m ago  │ │
│ └──────────────────────────────────────────────┘ │
│                                                   │
│ [Wake All] [Pause All] [View Run History]         │
└──────────────────────────────────────────────────┘
```

**Features:**
- Visual timeline: when each agent wakes up, color-coded
- Schedule cards: agent, cron expression (human-readable), next/last run, enabled toggle
- Create schedule: pick agent, set frequency (presets: every 15m/30m/1h/daily/weekly, or custom cron), set task context
- Wake-up queue: pending wake-up requests with priority
- Run history: past heartbeat runs with status (success/fail/paused/budget-stopped)
- Bulk actions: wake all, sleep all, pause all schedules
- Calendar view option (weekly/monthly view of scheduled runs)

### 6.16 Spawn (`/app/spawn`)

Launch new agent instances on demand.

**Form:**
- Select agent from roster (or create new temporary agent)
- Pick model (dropdown from available providers)
- Task description (what should this agent do)
- Workspace strategy: worktree (git isolation), docker (container), sandbox (restricted), shared
- Budget limit for this spawn
- Timeout (max execution time)
- Quick spawn presets (from `.canopy/templates/`)

**Active Instances:**
- List of currently spawned agents
- Status, elapsed time, token usage
- Kill button
- View output stream

**History:**
- Past spawns with outcomes (success/fail/timeout/budget-stopped)
- Relaunch button

### 6.17 Webhooks (`/app/webhooks`)

External trigger management.

**Types:**
- **Incoming**: URL endpoints that trigger agent actions (e.g., GitHub webhook → wake agent)
- **Outgoing**: Events that POST to external URLs (e.g., agent completes → notify Slack)

**Each webhook:**
- Name, type (in/out), URL, events subscribed, secret, status (active/disabled)
- Last triggered timestamp
- Delivery log (recent payloads, response codes)
- Test button (send test payload)
- Edit/delete

### 6.18 Alerts (`/app/alerts`)

Rule-based notification system.

**Rule Builder:**
```
┌──────────────────────────────────────────────┐
│ New Alert Rule                               │
│                                              │
│ Rule Name: [Agent Offline Alert           ]  │
│ Description: [Optional description        ]  │
│                                              │
│ Entity: [Agent ▼]    Field: [status ▼]       │
│ Operator: [= ▼]     Value: [error        ]  │
│                                              │
│ Cooldown: [60  ] minutes                     │
│ Notify: [system ▼]                           │
│                                              │
│         [Cancel]  [Create Rule]              │
└──────────────────────────────────────────────┘
```

**Entities:** Agent, Session, Budget, System, Gateway
**Fields:** status, cost, token_usage, error_count, latency, uptime
**Operators:** =, !=, >, <, >=, <=, contains
**Notify targets:** system (inbox), email, webhook, Slack

**Alert Dashboard:**
- Summary cards: Total Rules, Active, Total Triggers
- Active rules list with trigger counts
- Alert history (when each rule fired)
- Evaluate Now button (test all rules)

### 6.19 Integrations (`/app/integrations`)

Provider and service management. Tabbed by category.

**Tabs:**

| Tab | Services | Config |
|---|---|---|
| **AI Providers** | Anthropic, OpenAI, OpenRouter, Ollama, Google, local models | API key, connection test, model listing, set default |
| **Search** | Perplexity, Tavily, SerpAPI, Brave Search | API key, test query |
| **Social** | X/Twitter, LinkedIn | OAuth / access token |
| **Messaging** | Slack, Discord, WhatsApp | Webhook URL / bot token |
| **Dev Tools** | GitHub, GitLab, Linear, Jira | OAuth / personal access token, repo sync |
| **Security** | 1Password, HashiCorp Vault, AWS Secrets Manager | Connection config |
| **Infrastructure** | Docker, AWS, GCP, gateway connections | Endpoint + credentials |

**Each integration card:**
- Service name + icon
- Connection status: Connected (green) / Not Configured (gray) / Error (red)
- Configure button → modal with fields
- Disconnect button
- Last synced timestamp

**Actions:**
- "Pull All" — refresh all connection statuses
- "Save Changes" — persist to `.canopy/integrations/`

### 6.20 Users (`/app/users`)

Team management with RBAC.

**User Table:**
- User, Provider (local/OAuth), Role (admin/member/viewer), Last Login, Actions (Edit)
- Add Local User / Invite by Email
- Pending approvals for new users

**Roles:**
- **Admin**: Full access, can manage users, set budgets, approve hires
- **Member**: Can create issues, assign agents, view all data
- **Viewer**: Read-only access to dashboards and activity

### 6.21 Audit (`/app/audit`)

Immutable event trail. Every significant action logged.

**Events logged:**
- User login/logout
- Config changes
- Agent hired/fired/paused/terminated
- Budget policies set/changed
- Approvals granted/denied
- Workspace created/deleted
- Integration connected/disconnected
- Schedule created/modified
- Alert rules changed

**Features:**
- Filter by: action type, actor (user/agent/system), time range
- "All actions" / "Filter by actor" dropdowns
- Export audit log (CSV/JSON)
- Immutable — cannot be edited or deleted

### 6.22 Gateways (`/app/gateways`)

Connection infrastructure management.

**Layout:**
- Connection status banner (Connected / Disconnected + WebSocket URL)
- Gateway list:
  - Each gateway: URL, status badge (Connected/Disconnected), latency, token info, last probe time
  - Probe button (test connection)
  - Set Primary button
  - Delete button
- Add Gateway form (URL, token)
- Direct CLI Connections section (agents connected without gateway)

### 6.23 Config (`/app/config`)

System configuration viewer/editor.

**JSON Tree View:**
- Collapsible sections: meta, auth, agents, tools, messages, commands, channels, gateway, plugins
- Inline editing (click value to edit)
- Save Changes button
- Diff view (show changes from last saved state)
- Export/Import configuration
- Reset to defaults

### 6.24 Templates (`/app/templates`)

Workspace and team presets.

**Built-in Templates:**
- Engineering Team: Orchestrator + Code Worker + Reviewer + Tester
- Research Team: Lead Researcher + Data Analyst + Writer
- Content Team: Content Strategist + Writer + Editor
- Custom: User-created templates

**Features:**
- Preview template before applying (shows agent roster, skills, schedules)
- Apply to current workspace
- Create from current workspace (export as template)
- Secret scrubbing on export (removes API keys, tokens)
- Community templates (import from URL)

### 6.25 Workspaces (`/app/workspaces`)

Multi-workspace provisioning and admin.

**Layout:**
- KPI cards: Active Workspaces, Pending/In Progress, Errored, Queued Approvals
- Tabs: Workspaces, Jobs, Events

**Workspaces Tab:**
- Table: Name, System User, Owner, Status, Latest Job, Actions
- "+ Add Workspace" button
- Search and status filter
- Click workspace → detail view with agent roster, budget summary

**Jobs Tab:**
- Running workspace operations (cloning repos, setting up workspaces)
- History of past jobs

**Events Tab:**
- Workspace-level event log (created, activated, errored)

### 6.26 Terminal (`/app/terminal`)

Built-in terminal emulator. Always accessible via ⌘T.

**Features:**
- xterm.js with full PTY support
- Multiple tabs (split terminals)
- Working directory follows active workspace
- Command history
- Search within terminal output
- Font size controls
- Theme matched to app theme

### 6.27 Settings (`/app/settings`)

Application preferences.

**Tabs:**

| Tab | Content |
|---|---|
| **General** | Agent name, default working directory, language, notifications |
| **Providers** | Quick model switching (which AI provider + model to use by default) |
| **Voice** | Voice input/output settings (if supported) |
| **Permissions** | YOLO mode toggle, tool approval settings, destructive action gates |
| **Appearance** | Theme selection (Dark, Glass, Color, Light, System), font size, sidebar default state |
| **Advanced** | Backend URL, log level, debug mode, performance settings |
| **About** | Version info, Canopy protocol version, system health, "Powered by Canopy" |

---

## 7. Floating Panels

Panels are overlays accessible from ANY page via keyboard shortcut. They do not navigate — they float over the current page.

### 7.1 Chat Panel (`⌘/`)

**Position:** Right side, slides in from edge
**Width:** ~400px (resizable)

**Features:**
- Agent selector dropdown: Orchestrator, Research Agent, Code Worker, etc. (from workspace roster)
- Per-agent chat history
- SSE streaming with markdown rendering
- Shows WHICH agent is responding (name + model badge)
- Sub-agent delegation indicators:
  - "🔄 Delegated to Research Agent..."
  - "✅ Research Agent completed (2.3s, 1,245 tokens)"
- Tool call rendering (collapsible blocks showing what tools were called)
- Image/file attachment support
- Code block syntax highlighting
- Thinking/reasoning block display (collapsible)
- Input: text field + send button + attach button

### 7.2 Inspector Panel (`⌘I`)

**Position:** Bottom drawer, slides up
**Height:** ~250px (resizable)

**Content:**
- Currently executing agent + task
- Real-time tool call display (tool name, arguments, result)
- Reasoning steps (streamed thinking)
- Token counter (input/output/cache, running total)
- Elapsed time
- Cost accumulation (real-time $ counter)
- Pause/Resume execution
- Cancel button

### 7.3 File Browser (`⌘E`)

**Position:** Left overlay panel
**Width:** ~350px

**Content:**
- Full `.canopy/` directory tree
- File preview (markdown rendered, JSON formatted, YAML highlighted)
- Monaco editor for in-place editing
- Create new file/directory
- Delete file (with confirmation)
- Quick navigation to: SYSTEM.md, COMPANY.md, agent definitions, skills

### 7.4 Floating Activity Widget (Always On)

**Position:** Bottom-right corner, small pill
**Default:** Collapsed (shows icon + last event snippet)
**Expanded:** Shows last 5 events with timestamps

- Mounted at layout level (persists across ALL page navigation)
- Click to expand/collapse
- Click event → navigate to Activity page
- Subtle pulse animation when new event arrives
- Can be dismissed (reappears on next event)

---

## 8. Route Map

Complete route listing — 32 routes total.

```
ROUTE                        PAGE                    SECTION
─────────────────────────────────────────────────────────────
/app                         Dashboard               Core
/app/inbox                   Inbox                   Core
/app/office                  Virtual Office (2D/3D)  Core

/app/issues                  Issues (list + kanban)  OPS
/app/issues/[id]             Issue Detail            OPS
/app/goals                   Goal Hierarchy          OPS
/app/goals/[id]              Goal Detail             OPS
/app/documents               Document Browser        OPS

/app/projects                Projects Overview       PROJECTS
/app/projects/[id]           Project Detail          PROJECTS

/app/agents                  Agent Roster            TEAM
/app/agents/[id]             Agent Detail (7 tabs)   TEAM

/app/activity                Activity Feed           MONITOR
/app/sessions                Session Management      MONITOR
/app/sessions/[id]           Session Transcript      MONITOR
/app/logs                    Real-Time Log Viewer    MONITOR
/app/costs                   Financial Dashboard     MONITOR
/app/memory                  Knowledge Base          MONITOR
/app/signals                 Signal Theory Analysis  MONITOR

/app/skills                  Skill Marketplace       ORCHESTRATE
/app/schedules               Heartbeat Center        ORCHESTRATE
/app/spawn                   Launch Instances         ORCHESTRATE
/app/webhooks                Webhook Management      ORCHESTRATE
/app/alerts                  Alert Rule Builder      ORCHESTRATE
/app/integrations            Provider Management     ORCHESTRATE

/app/users                   Team Management         ADMIN
/app/audit                   Audit Trail             ADMIN
/app/gateways                Gateway Connections     ADMIN
/app/config                  Config Editor           ADMIN
/app/templates               Workspace Templates     ADMIN
/app/workspaces              Multi-Workspace Admin   ADMIN

/app/terminal                Terminal Emulator       Utility
/app/settings                App Settings            Utility
```

---

## 9. Component Architecture

### Directory Structure

```
desktop/src/lib/components/
├── layout/
│   ├── Sidebar.svelte              Main navigation sidebar
│   ├── SidebarSection.svelte       Collapsible section header
│   ├── SidebarNavItem.svelte       Individual nav item
│   ├── SidebarDynamicList.svelte   Dynamic project/agent list
│   ├── TitleBar.svelte             Window title bar
│   ├── PageShell.svelte            Page wrapper with header
│   ├── ChatPanel.svelte            Right-side chat slide-out
│   ├── InspectorPanel.svelte       Bottom execution inspector
│   ├── FileBrowser.svelte          Left file browser overlay
│   ├── ActivityWidget.svelte       Floating mini activity feed
│   ├── ConnectionStatusBar.svelte  Backend connection status
│   ├── WorkspaceSwitcher.svelte    Canopy workspace selector
│   ├── CreateWorkspaceModal.svelte Workspace creation dialog
│   ├── Toast.svelte                Toast notification
│   └── ToastContainer.svelte       Toast container
│
├── dashboard/
│   ├── KpiGrid.svelte              KPI summary cards
│   ├── LiveRunsWidget.svelte       Active execution display
│   ├── RecentActivityFeed.svelte   Recent events
│   ├── FinanceSummary.svelte       Spend overview
│   ├── QuickActions.svelte         Action buttons
│   └── SystemHealthBar.svelte      Health indicators
│
├── office/
│   ├── VirtualOffice.svelte        Container (switches 2D/3D)
│   ├── Office2D.svelte             SVG isometric floor plan
│   ├── Office3D.svelte             Threlte 3D scene
│   ├── AgentAvatar.svelte          Agent avatar with status
│   ├── AgentAvatar3D.svelte        3D character model
│   ├── DeskZone.svelte             Work area in spatial view
│   ├── SpeechBubble.svelte         Live activity text
│   ├── CollaborationLine.svelte    Agent-to-agent connection
│   └── OfficeDetailPanel.svelte    Click-agent side panel
│
├── inbox/
│   ├── InboxFeed.svelte            Notification list
│   ├── InboxFilters.svelte         Type/agent/priority filters
│   ├── InboxItem.svelte            Individual notification
│   ├── ApprovalCard.svelte         Approval request card
│   └── IncidentCard.svelte         Budget incident card
│
├── issues/
│   ├── IssueList.svelte            Issue table view
│   ├── IssueCard.svelte            Issue summary card
│   ├── IssueDetail.svelte          Full issue view
│   ├── IssueForm.svelte            Create/edit form
│   ├── KanbanBoard.svelte          Drag-and-drop kanban
│   ├── KanbanCard.svelte           Kanban item
│   └── CommentThread.svelte        Issue comments
│
├── goals/
│   ├── GoalHierarchy.svelte        Tree visualization
│   ├── GoalCard.svelte             Goal summary
│   ├── GoalDetail.svelte           Goal properties + linked items
│   └── GoalForm.svelte             Create/edit goal
│
├── documents/
│   ├── DocumentBrowser.svelte      File tree + viewer
│   ├── DocumentTree.svelte         Directory tree component
│   ├── DocumentViewer.svelte       Markdown/code renderer
│   └── DocumentEditor.svelte       Monaco inline editor
│
├── projects/
│   ├── ProjectCard.svelte          Project summary
│   ├── ProjectDetail.svelte        Project overview + workspaces
│   └── ProjectForm.svelte          Create/edit project
│
├── agents/
│   ├── AgentCard.svelte            Agent summary card
│   ├── AgentGrid.svelte            Card grid layout
│   ├── AgentDetail.svelte          Full agent view (7 tabs)
│   ├── AgentOverview.svelte        Overview tab
│   ├── AgentConfig.svelte          Config tab
│   ├── AgentSchedules.svelte       Schedules tab
│   ├── AgentSkills.svelte          Skills tab
│   ├── AgentRuns.svelte            Run history tab
│   ├── AgentBudget.svelte          Budget tab
│   ├── AgentInbox.svelte           Inter-agent messages tab
│   ├── OrgChart.svelte             Org chart visualization
│   ├── AgentNode.svelte            Node in org chart
│   ├── AgentTree.svelte            Hierarchical tree view
│   └── HireAgentDialog.svelte      New agent form
│
├── sessions/
│   ├── SessionCard.svelte          Session with token bar
│   ├── SessionList.svelte          Session grid/list
│   ├── SessionOverview.svelte      Stats sidebar
│   ├── SessionTranscript.svelte    Execution transcript viewer
│   └── ExecutionWorkspace.svelte   Workspace info display
│
├── monitor/
│   ├── ActivityFeed.svelte         Live event stream
│   ├── ActivityFilters.svelte      Filter controls
│   ├── ActivityRow.svelte          Individual event row
│   └── ActivityTable.svelte        Table view of events
│
├── logs/
│   ├── LogViewer.svelte            Real-time log stream
│   ├── LogFilters.svelte           Level/source/session filters
│   └── LogEntry.svelte             Individual log line
│
├── costs/
│   ├── CostDashboard.svelte        Main cost view
│   ├── CostChart.svelte            Daily cost line graph
│   ├── AgentCostBreakdown.svelte   Per-agent pie + table
│   ├── ModelDistribution.svelte    Per-model cost chart
│   ├── BudgetPolicyTable.svelte    Budget status per agent
│   ├── BudgetIncidentLog.svelte    Enforcement events
│   ├── AnomalyAlert.svelte         Spend spike warning
│   ├── CostTrends.svelte           Week-over-week comparison
│   └── CacheSavings.svelte         Prompt cache savings display
│
├── memory/
│   ├── MemoryBrowser.svelte        Knowledge base grid
│   ├── MemoryCard.svelte           Memory item card
│   ├── MemoryDetail.svelte         Memory viewer/editor
│   └── MemoryForm.svelte           Create/edit memory
│
├── signals/
│   ├── SignalFeed.svelte           Signal analysis stream
│   ├── SignalCard.svelte           Individual signal
│   ├── SignalFilters.svelte        Filter controls
│   ├── SignalPatterns.svelte       Pattern visualization
│   ├── SignalTypeBreakdown.svelte  Type distribution chart
│   ├── SignalChannelBreakdown.svelte Channel chart
│   ├── SignalWeightGauge.svelte    S/N quality gauge
│   └── SignalModeBar.svelte        Mode switcher
│
├── skills/
│   ├── SkillGrid.svelte            Skill marketplace grid
│   ├── SkillCard.svelte            Skill summary card
│   ├── SkillDetail.svelte          Skill detail slide-out
│   └── SkillForm.svelte            Import/create skill
│
├── schedules/
│   ├── ScheduleTimeline.svelte     Visual timeline (when agents wake)
│   ├── ScheduleCard.svelte         Schedule item
│   ├── ScheduleForm.svelte         Create/edit schedule
│   ├── WakeupQueue.svelte          Pending wake-up requests
│   ├── RunHistory.svelte           Past heartbeat runs
│   └── CronEditor.svelte          Cron expression editor (human-readable)
│
├── spawn/
│   ├── SpawnForm.svelte            Launch agent form
│   ├── SpawnPresets.svelte         Quick spawn templates
│   ├── ActiveInstances.svelte      Running spawned agents
│   └── SpawnHistory.svelte         Past spawn results
│
├── webhooks/
│   ├── WebhookCard.svelte          Webhook display
│   ├── WebhookForm.svelte          Create/edit webhook
│   └── WebhookLog.svelte           Delivery history
│
├── alerts/
│   ├── AlertRuleCard.svelte        Alert rule display
│   ├── AlertRuleForm.svelte        Rule builder form
│   └── AlertHistory.svelte         When rules triggered
│
├── integrations/
│   ├── IntegrationTabs.svelte      Category tab bar
│   ├── IntegrationCard.svelte      Provider/service card
│   ├── IntegrationForm.svelte      Configure integration modal
│   └── IntegrationStatus.svelte    Connection status badge
│
├── admin/
│   ├── UserList.svelte             Team member table
│   ├── UserForm.svelte             Invite/edit user
│   ├── AuditTrail.svelte           Audit event list
│   ├── AuditFilters.svelte         Audit filter controls
│   ├── GatewayCard.svelte          Gateway connection card
│   ├── GatewayForm.svelte          Add/edit gateway
│   ├── ConfigTree.svelte           JSON tree viewer/editor
│   ├── TemplateCard.svelte         Template preview card
│   ├── TemplatePreview.svelte      Full template preview
│   ├── WorkspaceTable.svelte       Multi-workspace admin table
│   └── WorkspaceForm.svelte        Create workspace form
│
├── chat/
│   ├── ChatMessages.svelte         Message list
│   ├── ChatInput.svelte            Message input + attachments
│   ├── ChatHeader.svelte           Agent selector + model badge
│   ├── MessageBubble.svelte        Individual message
│   ├── CodeBlock.svelte            Code display
│   ├── ToolCall.svelte             Tool execution display
│   ├── ThinkingBlock.svelte        Reasoning display
│   ├── StreamingCursor.svelte      Animated streaming cursor
│   ├── DelegationIndicator.svelte  Sub-agent delegation badge
│   └── AgentSelector.svelte        Agent picker dropdown
│
├── terminal/
│   ├── XTerminal.svelte            xterm.js emulator
│   ├── TerminalToolbar.svelte      Tab bar + controls
│   └── TerminalTab.svelte          Individual terminal tab
│
├── settings/
│   ├── SettingsGeneral.svelte
│   ├── SettingsProviders.svelte
│   ├── SettingsVoice.svelte
│   ├── SettingsPermissions.svelte
│   ├── SettingsAppearance.svelte
│   ├── SettingsAdvanced.svelte
│   └── SettingsAbout.svelte
│
├── shared/
│   ├── Badge.svelte                Count/status badge
│   ├── StatusDot.svelte            Online/offline/idle indicator
│   ├── TokenBar.svelte             Token usage progress bar
│   ├── BudgetBar.svelte            Budget usage progress bar
│   ├── EmptyState.svelte           "No data" placeholder
│   ├── ErrorState.svelte           Error display with retry
│   ├── LoadingSpinner.svelte       Loading indicator
│   ├── OfflineBanner.svelte        Backend offline message
│   ├── ConfirmDialog.svelte        Confirmation modal
│   ├── Tooltip.svelte              Hover tooltip
│   ├── Dropdown.svelte             Dropdown menu
│   ├── Tabs.svelte                 Tab bar
│   ├── Table.svelte                Data table
│   ├── SearchInput.svelte          Search field
│   ├── DatePicker.svelte           Date/time picker
│   ├── CronInput.svelte            Human-readable cron input
│   ├── MarkdownRenderer.svelte     Markdown display
│   ├── JsonTree.svelte             Collapsible JSON viewer
│   ├── Avatar.svelte               User/agent avatar
│   ├── MetricCard.svelte           KPI display card
│   └── TimeAgo.svelte              Relative time display
│
└── palette/
    ├── CommandPalette.svelte       ⌘K command palette
    └── PaletteItem.svelte          Individual palette result
```

**Total: ~160 components across 22 feature categories.**

---

## 10. Store Architecture

All stores use Svelte 5 class-based pattern with `$state` runes.

```
desktop/src/lib/stores/
├── workspace.svelte.ts        Active workspace, workspace list, .canopy/ state
├── connection.svelte.ts       Backend health, reconnection, offline queue
├── dashboard.svelte.ts        KPIs, live runs, system health, auto-refresh
├── inbox.svelte.ts            Notifications, approvals, unread count
├── agents.svelte.ts           Agent roster, active agents, status tracking
├── issues.svelte.ts           Issues, kanban state, filters, comments
├── goals.svelte.ts            Goal hierarchy, progress tracking
├── projects.svelte.ts         Project list, active project
├── sessions.svelte.ts         Active sessions, transcripts, execution workspaces
├── activity.svelte.ts         Event stream, filters, floating widget state
├── logs.svelte.ts             Log buffer, filters, stream connection
├── costs.svelte.ts            Finance ledger, budgets, incidents, anomalies
├── memory.svelte.ts           Knowledge base entries, search
├── signals.svelte.ts          Signal analysis, patterns, classifications
├── skills.svelte.ts           Skill registry, enabled/disabled state
├── schedules.svelte.ts        Heartbeat configs, wake-up queue, run history
├── spawn.svelte.ts            Active instances, spawn history
├── webhooks.svelte.ts         Webhook configs, delivery logs
├── alerts.svelte.ts           Alert rules, trigger history
├── integrations.svelte.ts     Provider connections, service status
├── users.svelte.ts            Team members, roles
├── audit.svelte.ts            Audit events, filters
├── gateways.svelte.ts         Gateway connections, latency
├── config.svelte.ts           System configuration tree
├── templates.svelte.ts        Workspace/team templates
├── workspaces.svelte.ts       Multi-workspace admin state
├── chat.svelte.ts             Chat messages, streaming, agent selection
├── theme.svelte.ts            Theme/appearance preferences
├── voice.svelte.ts            Voice settings
├── permissions.svelte.ts      Permission dialogs, YOLO mode
├── palette.svelte.ts          Command palette state
├── toasts.svelte.ts           Toast notifications
└── settings.svelte.ts         User preferences persistence
```

**Total: 33 stores.**

---

## 11. Adapter System

Adapters connect the Command Center to different AI agent runtimes. Each adapter implements a standard interface for heartbeat execution, session management, and lifecycle hooks.

### Adapter Interface

```typescript
interface AgentAdapter {
  // Identity
  type: string;                          // "osa" | "claude-code" | "codex" | etc.
  name: string;                          // Human-readable name

  // Lifecycle
  start(config: AgentConfig): Promise<AdapterSession>;
  stop(session: AdapterSession): Promise<void>;

  // Heartbeat (proactive execution)
  executeHeartbeat(params: HeartbeatParams): AsyncGenerator<HeartbeatEvent>;

  // Communication
  sendMessage(session: AdapterSession, message: string): AsyncGenerator<StreamEvent>;

  // Hooks
  onHireApproved?(payload: HirePayload): Promise<void>;
  onTerminate?(payload: TerminatePayload): Promise<void>;

  // Session management
  supportsSession: boolean;              // Can maintain context across heartbeats
  supportsConcurrent: boolean;           // Can run multiple heartbeats simultaneously

  // Capabilities
  capabilities: AdapterCapability[];     // ["tool_calling", "vision", "streaming", etc.]
}
```

### Available Adapters

| Adapter | Type | Session Support | Description |
|---|---|---|---|
| **OSA** | `osa` | Yes | Elixir/OTP GenServer — our primary. Full tool calling, multi-agent delegation, Signal Theory. |
| **Claude Code** | `claude-code` | Yes | Claude Code CLI. Spawns `claude` process, reads stdout, manages context. |
| **Codex** | `codex` | Yes | OpenAI Codex CLI. Similar to Claude Code adapter. |
| **OpenClaw** | `openclaw` | Yes | Connects to OpenClaw gateway via WebSocket. Full agent protocol. |
| **Cursor** | `cursor` | Yes | Cursor editor integration. Spawns cursor background agent. |
| **Gemini** | `gemini` | Yes | Google Gemini CLI adapter. |
| **Bash** | `bash` | No | Raw shell execution. Runs a script, captures output. No session persistence. |
| **HTTP** | `http` | No | Generic HTTP heartbeat. POST task → GET result. For custom/remote agents. |

---

## 12. Backend API Surface

The Command Center communicates with the backend via REST API + SSE + WebSocket.

### REST Endpoints (~80 routes)

**Workspace**
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

**Agents**
```
GET    /api/v1/agents
POST   /api/v1/agents
GET    /api/v1/agents/:id
PATCH  /api/v1/agents/:id
DELETE /api/v1/agents/:id
POST   /api/v1/agents/:id/wake
POST   /api/v1/agents/:id/sleep
POST   /api/v1/agents/:id/pause
POST   /api/v1/agents/:id/resume
POST   /api/v1/agents/:id/focus
POST   /api/v1/agents/:id/terminate
GET    /api/v1/agents/:id/runs
GET    /api/v1/agents/:id/inbox
GET    /api/v1/agents/hierarchy
```

**Issues**
```
GET    /api/v1/issues
POST   /api/v1/issues
GET    /api/v1/issues/:id
PATCH  /api/v1/issues/:id
DELETE /api/v1/issues/:id
POST   /api/v1/issues/:id/assign
POST   /api/v1/issues/:id/comments
GET    /api/v1/issues/:id/comments
POST   /api/v1/issues/:id/checkout
```

**Goals**
```
GET    /api/v1/goals
POST   /api/v1/goals
GET    /api/v1/goals/:id
PATCH  /api/v1/goals/:id
DELETE /api/v1/goals/:id
GET    /api/v1/goals/:id/ancestry
```

**Projects**
```
GET    /api/v1/projects
POST   /api/v1/projects
GET    /api/v1/projects/:id
PATCH  /api/v1/projects/:id
DELETE /api/v1/projects/:id
GET    /api/v1/projects/:id/goals
GET    /api/v1/projects/:id/workspaces
```

**Sessions**
```
GET    /api/v1/sessions
GET    /api/v1/sessions/:id
GET    /api/v1/sessions/:id/transcript
DELETE /api/v1/sessions/:id
POST   /api/v1/sessions/:id/message
```

**Schedules**
```
GET    /api/v1/schedules
POST   /api/v1/schedules
GET    /api/v1/schedules/:id
PATCH  /api/v1/schedules/:id
DELETE /api/v1/schedules/:id
POST   /api/v1/schedules/:id/trigger
GET    /api/v1/schedules/queue
POST   /api/v1/schedules/wake-all
POST   /api/v1/schedules/pause-all
```

**Costs & Budgets**
```
GET    /api/v1/costs/summary
GET    /api/v1/costs/by-agent
GET    /api/v1/costs/by-model
GET    /api/v1/costs/daily
GET    /api/v1/costs/events
GET    /api/v1/budgets
PUT    /api/v1/budgets/:scope_type/:scope_id
GET    /api/v1/budgets/incidents
POST   /api/v1/budgets/incidents/:id/resolve
```

**Skills**
```
GET    /api/v1/skills
GET    /api/v1/skills/:id
POST   /api/v1/skills/:id/toggle
POST   /api/v1/skills/bulk-enable
POST   /api/v1/skills/bulk-disable
GET    /api/v1/skills/categories
```

**Memory**
```
GET    /api/v1/memory
POST   /api/v1/memory
GET    /api/v1/memory/:id
PATCH  /api/v1/memory/:id
DELETE /api/v1/memory/:id
GET    /api/v1/memory/search?q=
```

**Signals**
```
POST   /api/v1/signals/classify
GET    /api/v1/signals/feed
GET    /api/v1/signals/patterns
GET    /api/v1/signals/stats
```

**Integrations**
```
GET    /api/v1/integrations
POST   /api/v1/integrations/:slug/connect
DELETE /api/v1/integrations/:slug
GET    /api/v1/integrations/:slug/status
POST   /api/v1/integrations/pull-all
```

**Webhooks**
```
GET    /api/v1/webhooks
POST   /api/v1/webhooks
GET    /api/v1/webhooks/:id
PATCH  /api/v1/webhooks/:id
DELETE /api/v1/webhooks/:id
POST   /api/v1/webhooks/:id/test
GET    /api/v1/webhooks/:id/deliveries
```

**Alerts**
```
GET    /api/v1/alerts/rules
POST   /api/v1/alerts/rules
GET    /api/v1/alerts/rules/:id
PATCH  /api/v1/alerts/rules/:id
DELETE /api/v1/alerts/rules/:id
POST   /api/v1/alerts/evaluate
GET    /api/v1/alerts/history
```

**Admin**
```
GET    /api/v1/users
POST   /api/v1/users
PATCH  /api/v1/users/:id
DELETE /api/v1/users/:id
GET    /api/v1/audit
GET    /api/v1/gateways
POST   /api/v1/gateways
DELETE /api/v1/gateways/:id
POST   /api/v1/gateways/:id/probe
GET    /api/v1/config
PATCH  /api/v1/config
GET    /api/v1/templates
POST   /api/v1/templates
GET    /api/v1/health
GET    /api/v1/dashboard
```

**Spawn**
```
POST   /api/v1/spawn
GET    /api/v1/spawn/active
DELETE /api/v1/spawn/:id
GET    /api/v1/spawn/history
```

**Activity & Logs**
```
GET    /api/v1/activity
GET    /api/v1/activity/stream          (SSE)
GET    /api/v1/logs/stream              (SSE)
```

**Documents**
```
GET    /api/v1/documents
GET    /api/v1/documents/*path
PUT    /api/v1/documents/*path
DELETE /api/v1/documents/*path
POST   /api/v1/documents
```

### SSE Endpoints

```
GET /api/v1/activity/stream       Live event feed
GET /api/v1/logs/stream           Real-time log streaming
GET /api/v1/sessions/:id/stream   Session execution stream (tool calls, output)
```

### WebSocket

```
ws://localhost:9089/ws            Bidirectional: chat, inspector, live updates
```

---

## 13. Real-Time Communication

### SSE (Server-Sent Events)

Used for one-way streaming from server to client:
- Activity feed (event stream)
- Log viewer (real-time logs)
- Session execution (tool calls, reasoning, output)
- Cost updates (token count changes)

### WebSocket

Used for bidirectional communication:
- Chat (send messages + receive streaming responses)
- Inspector (real-time execution state)
- Gateway health (connection status pings)

### Event Types

```typescript
type EventType =
  // Agent lifecycle
  | "agent.status_changed"      // idle → working → error
  | "agent.heartbeat_started"   // heartbeat run began
  | "agent.heartbeat_completed" // heartbeat run finished
  | "agent.hired"               // new agent added
  | "agent.terminated"          // agent removed
  | "agent.paused"
  | "agent.resumed"

  // Execution
  | "run.started"
  | "run.tool_call"             // tool invocation
  | "run.tool_result"           // tool response
  | "run.thinking"              // reasoning step
  | "run.output"                // text output chunk
  | "run.completed"
  | "run.failed"
  | "run.cancelled"

  // Work
  | "issue.created"
  | "issue.assigned"
  | "issue.status_changed"
  | "issue.commented"
  | "goal.progress_updated"
  | "project.updated"

  // Budget
  | "budget.warning"            // threshold hit
  | "budget.hard_stop"          // limit exceeded, agent paused
  | "budget.incident_resolved"

  // System
  | "gateway.connected"
  | "gateway.disconnected"
  | "config.changed"
  | "workspace.activated"
  | "alert.triggered"
  | "webhook.received"
  | "user.logged_in"
```

---

## 14. Design System

### Foundation CSS Variables

The Command Center uses the MIOSA Foundation design system — glassmorphic dark-mode with CSS custom properties.

```css
/* Backgrounds */
--bg-primary: rgba(10, 10, 10, 0.95);
--bg-secondary: rgba(20, 20, 20, 0.85);
--bg-elevated: rgba(30, 30, 30, 0.9);
--bg-glass: rgba(255, 255, 255, 0.05);

/* Text */
--text-primary: rgba(255, 255, 255, 0.95);
--text-secondary: rgba(255, 255, 255, 0.7);
--text-tertiary: rgba(255, 255, 255, 0.5);
--text-muted: rgba(255, 255, 255, 0.3);

/* Accents */
--accent-primary: #3b82f6;    /* Blue */
--accent-success: #22c55e;    /* Green */
--accent-warning: #f59e0b;    /* Amber */
--accent-danger: #ef4444;     /* Red */
--accent-info: #06b6d4;       /* Cyan */

/* Borders */
--border-default: rgba(255, 255, 255, 0.08);
--border-hover: rgba(255, 255, 255, 0.15);
--border-active: rgba(59, 130, 246, 0.5);

/* Effects */
--glass-blur: blur(20px);
--shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3);
--shadow-md: 0 4px 12px rgba(0, 0, 0, 0.4);
--shadow-lg: 0 8px 32px rgba(0, 0, 0, 0.5);

/* Spacing */
--space-xs: 4px;
--space-sm: 8px;
--space-md: 16px;
--space-lg: 24px;
--space-xl: 32px;

/* Radius */
--radius-sm: 6px;
--radius-md: 8px;
--radius-lg: 12px;
--radius-xl: 16px;

/* Sidebar */
--sidebar-expanded-width: 260px;
--sidebar-collapsed-width: 60px;
--sidebar-bg: rgba(10, 10, 10, 0.85);
--sidebar-border: var(--border-default);
```

### Themes

Five theme options (matching ClawPort's approach):

| Theme | Description |
|---|---|
| **Dark** (default) | Pure dark with glassmorphism |
| **Glass** | More pronounced glass effects, blur, transparency |
| **Color** | Dark base with colorful accent gradients |
| **Light** | Light mode (inverted colors) |
| **System** | Follows OS dark/light preference |

### Typography

```css
--font-sans: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
--font-mono: 'JetBrains Mono', 'Fira Code', monospace;

--text-xs: 11px;
--text-sm: 13px;
--text-base: 14px;
--text-lg: 16px;
--text-xl: 20px;
--text-2xl: 24px;
```

---

## 15. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘1` | Dashboard |
| `⌘2` | Inbox |
| `⌘3` | Office |
| `⌘T` | Terminal |
| `⌘,` | Settings |
| `⌘K` | Command Palette (global search) |
| `⌘/` | Toggle Chat Panel |
| `⌘I` | Toggle Inspector Panel |
| `⌘E` | Toggle File Browser |
| `⌘\` | Toggle Sidebar collapse |
| `⌘N` | New Issue |
| `⌘⇧N` | Spawn Agent |
| `Esc` | Close active panel/modal |

---

## 16. Reference Apps

This design synthesizes features from five open-source agent orchestration platforms:

| App | Repo | Key Contribution |
|---|---|---|
| **Paperclip** | `paperclipai/paperclip` | Heartbeat system, execution workspaces, budget enforcement, finance ledger, hire hooks, adapter pattern, plugin system, company portability, clean sidebar design (dynamic lists) |
| **OpenClaw Office** | `WW-AI-Lab/openclaw-office` | Virtual Office (2D/3D), gateway manager, audit trail, integrations by category, alert rule builder, chat dock, super admin, multi-user |
| **ClawPort UI** | `JohnRiceML/clawport-ui` | Org map visualization, floating activity widget, cost anomaly detection, SOUL.md agent discovery, memory browser, 5 themes |
| **Hermes Workspace** | `outsourc-e/hermes-workspace` | File browser + Monaco editor, Inspector panel, PWA support, multi-provider (Anthropic/OpenAI/OpenRouter/Ollama) |
| **ClawTeam** | `HKUDS/ClawTeam` | Swarm self-organization, agent inbox (inter-agent messaging), team templates (TOML), git worktree isolation, leader/worker coordination |

### What's Uniquely Ours (Not in Any Reference)

| Feature | Description |
|---|---|
| **Signal Theory** | S=(M,G,T,F,W) analysis, S/N optimization, failure mode classification. From Roberto H Luna's "Signal Theory: The Architecture of Optimal Intent Encoding." |
| **Canopy Protocol** | `.canopy/` directory spec — open workspace protocol for AI agents. Portable, filesystem-based, tool-agnostic. |
| **Foundation Design System** | 124-component glassmorphic dark-mode design system from MIOSA. |
| **Elixir/OTP Backend** | OSA's primary adapter uses Elixir supervision trees, GenServers, ETS — production-grade fault tolerance. |
| **Terminal as First-Class** | Always-accessible built-in terminal. Not a tab — a persistent utility. |

---

## 17. Implementation Phases

### Phase 1: Foundation (Week 1-2)
- Scaffold Canopy monorepo (desktop + protocol + adapters)
- SvelteKit + Tauri project setup
- Foundation CSS variables + theme system
- Sidebar component with collapsible sections
- Core layout (TitleBar, PageShell, routing)
- Dashboard page (static, then wired)
- Connection store + health check

### Phase 2: Core Navigation (Week 2-3)
- All 32 route pages (shells with PageShell)
- Workspace switcher + .canopy/ discovery (Tauri filesystem)
- Dynamic sidebar lists (PROJECTS from .canopy/projects/, TEAM from .canopy/agents/)
- Command palette (⌘K)
- Chat side panel (⌘/) — basic SSE streaming
- Settings page

### Phase 3: Agent Management (Week 3-4)
- Agent roster (grid + org chart + table views)
- Agent detail page (7 tabs)
- Hire Agent dialog
- Agent actions (wake, sleep, pause, terminate)
- Heartbeat scheduling system
- Schedules page with timeline view
- Spawn page

### Phase 4: Work Management (Week 4-5)
- Issues page (list + kanban + table)
- Issue detail with comments, work products
- Goals page with hierarchy tree
- Projects page with detail view
- Documents browser + editor
- Inbox (unified notifications)

### Phase 5: Observability (Week 5-6)
- Activity feed (SSE streaming)
- Floating activity widget
- Sessions page with token bars
- Session transcript viewer
- Log viewer (real-time streaming)
- Costs dashboard + budget enforcement
- Memory browser

### Phase 6: Automation (Week 6-7)
- Skills marketplace
- Webhooks management
- Alert rule builder
- Integrations page (tabbed by category)
- Adapter connection management

### Phase 7: Virtual Office (Week 7-8)
- Office 2D (SVG isometric floor plan)
- Agent avatars with status animations
- Speech bubbles, collaboration lines
- Click-agent detail panel
- Office 3D (Threlte scene)
- 2D ⟷ 3D toggle

### Phase 8: Admin & Polish (Week 8-9)
- Users + RBAC
- Audit trail
- Gateways management
- Config editor
- Templates system
- Workspaces admin
- Inspector panel (⌘I)
- File browser panel (⌘E)
- Signals page (Signal Theory)

### Phase 9: Integration & Testing (Week 9-10)
- Wire all stores to real backend endpoints
- Adapter integration testing (OSA, Claude Code)
- End-to-end heartbeat execution flow
- Budget enforcement testing
- Performance optimization
- Accessibility audit
- Build verification (svelte-check + production build)

---

## Appendix: Glossary

| Term | Definition |
|---|---|
| **Canopy** | The workspace protocol. A `.canopy/` directory that defines agents, skills, projects, and knowledge for a workspace. |
| **Command Center** | The desktop application itself. The user's operations room. |
| **Heartbeat** | A proactive agent execution cycle. The agent wakes on schedule, checks for work, executes, reports back. |
| **Adapter** | A connector between the Command Center and an AI agent runtime (OSA, Claude Code, Codex, etc.). |
| **Execution Workspace** | An isolated environment (git worktree, container, sandbox) where an agent runs a specific task. |
| **Budget Policy** | Per-agent spending limits with warning thresholds and hard stops. |
| **Signal** | A structured output analyzed through Signal Theory: S=(M,G,T,F,W). |
| **Hire** | Adding a new agent to the workspace roster. Business metaphor for agent creation. |
| **Spawn** | Launching a temporary agent instance for a specific task. |
| **Routine/Schedule** | A recurring heartbeat configuration. When and how often an agent wakes to do work. |
| **Foundation** | The MIOSA design system — CSS variables, components, glassmorphic styling. |
| **Inbox** | Unified notification center — approvals, alerts, mentions, failures. |
| **Office** | The Virtual Office — 2D/3D spatial visualization of agents at work in the workspace. |

---

*This document is the single source of truth for the Canopy Command Center desktop application. All implementation should reference this spec.*
