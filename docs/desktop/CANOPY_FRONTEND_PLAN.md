# Canopy Command Center — Frontend Implementation Plan

> For the frontend developer agent. Backend plan: `CANOPY_BACKEND_PLAN.md`. Master spec: `CANOPY_COMMAND_CENTER.md`.

## Context

Full desktop app rebuild for orchestrating proactive autonomous AI agents. **This plan covers FRONTEND ONLY** (SvelteKit + Tauri). A separate agent handles the backend (Elixir/OTP API, adapters, heartbeat runtime, database). Frontend builds against a **mock API layer** so both proceed in parallel.

**Existing code to port from**: `/Users/rhl/Desktop/MIOSA/code/OptimalSystemAgent/desktop/` — 100+ Svelte 5 components, 26 stores, full API client, Tauri 2 integration, Foundation CSS.

---

## Frontend/Backend Contract

### What Frontend Owns
- `canopy/desktop/` — SvelteKit 2 + Tauri 2 application
- `canopy/desktop/src-tauri/` — Rust IPC commands (.canopy/ filesystem scanner)
- `canopy/protocol/` — Canopy Protocol spec + JSON schemas + templates
- All UI: ~218 components, 33 stores, 32 routes
- Mock API layer (`src/lib/api/mock/`) — fake data for all ~80 endpoints
- TypeScript types (`src/lib/api/types.ts`) — the shared contract

### What Backend Owns
- `canopy/backend/` — Elixir/OTP API server
- All ~80 REST endpoints, 3 SSE streams, 1 WebSocket
- Adapter runtime, heartbeat scheduler, budget enforcement, database, auth

### Mock API Strategy
Every store calls through `api/client.ts`. In dev mode (no backend), client falls back to `api/mock/*.ts` with realistic fake data + simulated delays.

```
src/lib/api/
├── client.ts          # Real API client (fetch-based)
├── sse.ts             # SSE streaming client
├── websocket.ts       # WebSocket client
├── types.ts           # Full TypeScript contract (~80 interfaces)
└── mock/
    ├── index.ts       # Mock router — intercepts fetch in dev mode
    ├── agents.ts      # Fake agent data + CRUD
    ├── issues.ts      # Fake issues, kanban state
    ├── schedules.ts   # Fake schedules, heartbeat runs
    ├── costs.ts       # Fake finance data, budget policies
    ├── activity.ts    # Simulated SSE event stream
    ├── sessions.ts    # Fake session list + transcripts
    └── ...            # One mock file per API domain
```

---

## Phase 1: Foundation (Week 1-2) — 23 components, 6 stores

### Scaffold Canopy Monorepo
```
canopy/
├── desktop/                 SvelteKit 2 + Tauri 2
│   ├── src/
│   │   ├── app.css          Foundation CSS (ported + extended)
│   │   ├── lib/
│   │   │   ├── api/         client, sse, types, websocket, mock/
│   │   │   ├── components/  layout/, dashboard/, shared/
│   │   │   ├── stores/      6 initial stores
│   │   │   ├── utils/       platform.ts, backend.ts
│   │   │   └── types/       canopy.ts
│   │   └── routes/          app/ + onboarding/
│   ├── src-tauri/           Rust backend + .canopy/ scanner
│   ├── package.json, svelte.config.js, vite.config.ts
├── protocol/                Spec + schemas + templates
└── docs/
```

### Dependencies
**npm**: `@tauri-apps/api@^2`, Tauri plugins, `@xterm/xterm@^5` + addons, `dompurify`, `marked`, `highlight.js`, `tailwindcss@^4`
**Cargo.toml**: `notify@6`, `walkdir@2`, `glob@0.3`, `yaml-rust2@0.9`

### Port vs Rewrite
- **Port directly**: PageShell, TitleBar, ConnectionStatusBar, Toast, SSE client, utils
- **Port + extend**: app.css (add Glass/Color themes), agents store, API client (add mock fallback), dashboard components
- **Full rewrite**: Sidebar (collapsible sections), theme store (5 themes)

### Build Order
1. **Day 1-2**: Infrastructure — scaffold project, port configs, extend CSS
2. **Day 2-3**: API layer + mock system — types.ts (~40 interfaces), client.ts (mock fallback), mock/*.ts
3. **Day 3-4**: Core stores — toasts, connection, palette, workspace, theme (5 themes), dashboard
4. **Day 4-5**: Shared components (8) — Badge, StatusDot, MetricCard, LoadingSpinner, EmptyState, TokenBar, BudgetBar, TimeAgo
5. **Day 5-7**: Layout (9) — port PageShell/TitleBar/Toast, create SidebarNavItem, SidebarSection, SidebarDynamicList, full Sidebar rewrite
6. **Day 7-9**: Dashboard (6) — KpiGrid, LiveRunsWidget, RecentActivityFeed, FinanceSummary, QuickActions, SystemHealthBar
7. **Day 9-10**: App layout — port +layout.svelte with keyboard shortcuts
8. **Day 10-12**: Tauri Rust — port commands, create filesystem.rs (5 IPC commands for .canopy/ scanning)

---

## Phase 2: Core Navigation (Week 2-3) — 52 components, 4 stores

- **32 route page shells** — minimal PageShell wrappers for all routes
- **.canopy/ scanner** — 5 Rust IPC commands (discover, scan, read/write agent defs, watch)
- **Workspace switcher** — dropdown, open/create workspace
- **Dynamic sidebar lists** — PROJECTS + TEAM from .canopy/
- **Command palette (⌘K)** — 6 search sources
- **Chat side panel (⌘/)** — floating right panel, 11 components (port 8 chat components + 3 new)
- **Settings page** — 7 tabs (port 6, create Appearance)

---

## Phase 3: Agent Management (Week 3-4) — 27 components, 3 stores

- **Agent roster** — 3 views (grid, org chart, table), 7 components
- **Agent detail** — 7 tabs (Overview, Config, Schedules, Skills, Runs, Budget, Inbox)
- **Hire Agent dialog** — 7-section form (identity, adapter, model, config, budget, schedule, skills)
- **Schedules page** — timeline, schedule cards, CronEditor, wake-up queue, run history
- **Spawn page** — form, presets, active instances, history

---

## Phase 4: Work Management (Week 4-5) — 27 components, 4 stores

- **Issues** — 3 views (list, kanban with 5 columns, table), 9 components
- **Goals** — recursive hierarchy tree, 4 components
- **Documents** — split-pane browser with markdown viewer + Monaco editor, 4 components
- **Inbox** — unified notifications with inline actions, 3 components

---

## Phase 5: Observability (Week 5-6) — 31 components, 4 stores

- **Activity feed** — SSE streaming + floating widget (layout-level), 4 components
- **Sessions** — cards with token bars, transcript viewer, 5 components
- **Log viewer** — real-time streaming, ring buffer 10K, auto-scroll, 3 components
- **Costs dashboard** — 9 sections (summary, charts, budgets, incidents, anomalies), 9 components
- **Memory browser** — port existing, 4 components
- Chart library: Layerchart or Chart.js

---

## Phase 6: Automation (Week 6-7) — 23 components, 5 stores

- **Skills marketplace** — grid + detail + import, 4 components
- **Webhooks** — incoming/outgoing, delivery log, 3 components
- **Alerts** — rule builder (entity/field/operator/value), 4 components
- **Integrations** — 7 category tabs, dynamic config forms, 4 components
- **Adapters** — card + test, 2 components

---

## Phase 7: Virtual Office (Week 7-8) — 10 components, 1 store

**Dependencies**: `@threlte/core`, `@threlte/extras`, `three`

- **2D mode** — SVG isometric floor, agent avatars with status animations (breathing/typing/speaking/error), speech bubbles, collaboration lines
- **3D mode** — Threlte scene, low-poly characters, holographic skills, bloom+SSAO, orbit controls
- **Detail panel** — right slide-out on agent click
- **Performance** — Three.js lazy-loaded, CSS animations for 2D, `frameloop="demand"` for 3D

---

## Phase 8: Admin & Polish (Week 8-9) — 25 components, 6 stores

- **Admin pages (11)**: Users+RBAC, Audit trail, Gateways, Config editor, Templates, Workspaces admin
- **Floating panels (2)**: Inspector (⌘I), File browser (⌘E) with Monaco
- **Signals extension**: Failure mode classification (Shannon/Ashby/Beer/Wiener)
- **Dependency**: `monaco-editor`

---

## Phase 9: Integration & Testing (Week 9-10)

- Wire mock API to real backend (priority: agents, sessions, issues, goals, schedules first)
- SSE + WebSocket integration
- Performance: lazy loading, virtual scroll, debounce, SSE multiplexer
- Accessibility: WCAG 2.1 AA, keyboard nav, aria-labels, reduced motion
- Build: svelte-check, vitest 80%+, vite build, tauri build

---

## Totals

| Phase | Components | Stores | Key Deliverable |
|-------|-----------|--------|-----------------|
| 1-9 | **~218** | **33** | Full desktop app with mock API |

## Source Files to Port

| File | Path | Action |
|------|------|--------|
| Foundation CSS | `OSA/desktop/src/app.css` | Port + extend |
| App layout | `OSA/desktop/src/routes/app/+layout.svelte` | Port + adapt |
| API client | `OSA/desktop/src/lib/api/client.ts` | Port + restructure |
| SSE client | `OSA/desktop/src/lib/api/sse.ts` | Port directly |
| API types | `OSA/desktop/src/lib/api/types.ts` | Port + extend massively |
| Agent store | `OSA/desktop/src/lib/stores/agents.svelte.ts` | Port + extend |
| All stores | `OSA/desktop/src/lib/stores/*.svelte.ts` | Port selectively |
| Chat components | `OSA/desktop/src/lib/components/chat/` | Port directly |
| Layout components | `OSA/desktop/src/lib/components/layout/` | Port + rewrite Sidebar |
| Master spec | `OSA/docs/desktop/CANOPY_COMMAND_CENTER.md` | Reference (source of truth) |
