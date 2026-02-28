# TUI Roadmap & Status

> Go TUI (`bin/osa`) — current state, completed work, and planned features.
> Last updated: 2026-02-28

---

## Development History

| Commit | Date | Change |
|--------|------|--------|
| `797ca48` | Feb 24 | Initial Go TUI, auth flow, CLI flags, missing commands |
| `360aa04` | Feb 24 | `bin/osa` one-command launcher |
| `aab3638` | Feb 25 | UI/UX foundation — branding, header, phrases, status bar |
| `e85983a` | Feb 25 | HTTP timeout, model field, phrase rotation, response parsing |
| `f03aa7e` | Feb 25 | SSE event routing, model display, runtime paths, port handling |
| `43464d9` | Feb 26 | Strip thinking tokens, runtime paths, TUI polish |
| `232accb` | Feb 26 | Top-align welcome, inline activity during processing |
| `810ad70` | Feb 28 | OpenCode feature parity — multi-line input, sessions, tasks, keybindings |
| `eb117d0` | Feb 28 | TUI-backend alignment — command routing, swarm events, dynamic help |
| `0c93efc` | Feb 28 | Restore /clear as local command |
| `b9fe501` | Feb 28 | Resolve remaining 4 bugs + hardening |
| `ec37944` | Feb 28 | Swarm pattern validation + provider-aware model resolution |

**Total TUI-touching commits:** 15 over 5 days

---

## Architecture

```
priv/go/tui/
├── main.go              Entry point; flags, profile, OAuth, program init
├── app/
│   ├── app.go           Root Model; message routing, SSE, auth, commands, state
│   ├── state.go         State machine (6 states)
│   └── keymap.go        All key bindings
├── client/
│   ├── http.go          REST client (14 active endpoints)
│   ├── types.go         Request/response DTOs
│   └── sse.go           SSE streaming + reconnect (19 event types)
├── model/
│   ├── chat.go          Scrollable message viewport
│   ├── input.go         Text input + history + tab completion
│   ├── activity.go      Spinner, tool calls, token counter
│   ├── agents.go        Multi-agent swarm panel
│   ├── banner.go        Startup splash + header
│   ├── status.go        Signal bar, context util, provider info
│   ├── tasks.go         Task checklist with live status
│   ├── plan.go          Plan review (approve/reject/edit)
│   ├── picker.go        Model selector UI
│   └── phrases.go       95 witty phrases
├── msg/msg.go           Tea.Msg types (import-cycle-free)
├── style/style.go       Lipgloss palette + component styles
└── markdown/render.go   Glamour markdown → ANSI
```

**Stats:** 20 files | ~4,500 LoC | 9 UI components | 6 states | 4 target platforms

---

## State Machine

```
Connecting ──[health OK]──→ Banner ──[any key]──→ Idle
                                                   ↕ [submit / response]
                                               Processing
                                                   ↕ [plan detected / decision]
                                               PlanReview
                                                   ↕ [/models / selection]
                                               ModelPicker
```

---

## Completed Features (v0.1)

### Core
- [x] Backend health check with retry loop (5s interval)
- [x] Named profiles (`~/.osa/profiles/<name>/`)
- [x] Environment overrides (OSA_URL, OSA_TOKEN)
- [x] Dev mode (--dev → profile=dev, port=19001)
- [x] Graceful shutdown with confirm-quit

### Chat & I/O
- [x] Scrollable viewport with user/agent/system messages
- [x] Three system message levels (info, warning, error)
- [x] Welcome screen (version, provider, model, tools, workspace)
- [x] 100KB message truncation
- [x] Markdown → ANSI rendering (Glamour)
- [x] Multi-line input (Alt+Enter, up to 6 lines)
- [x] Input history (Up/Down)
- [x] Tab completion for slash commands

### Commands
- [x] Built-in: /help, /clear, /exit, /quit, /login, /logout, /bg
- [x] Backend-dispatched: /status, /agents, /tools, /sessions, etc.
- [x] Dynamic help from backend (80+ commands, grouped by 16 categories)
- [x] Custom command expansion (prompt → agent dispatch)
- [x] Command kind routing (text/prompt/action/error)
- [x] Action handling (:new_session, :exit, :clear, {:resume_session, ...})

### Auth
- [x] JWT bearer token auth
- [x] /login, /logout commands
- [x] Token file persistence (mode 0600)
- [x] SSE 401 detection → re-auth prompt
- [x] Token expiration countdown

### Sessions
- [x] Session ID generation (tui_<unix>_<rand>)
- [x] /sessions, /session new, /session <id>
- [x] Session-scoped SSE with auto-reconnect on switch

### Models
- [x] /models → picker UI (arrow keys, Enter/Esc)
- [x] /model (show current), /model <provider>/<name> (switch)
- [x] Active model highlight in picker
- [x] Provider/model in header and status bar

### Processing & Activity
- [x] Spinner with 95 witty phrases (4s rotation)
- [x] Elapsed timer
- [x] Tool call feed (inline in chat during processing)
- [x] Tool start/end with success/failure indicators
- [x] Token counter (input/output, formatted as 1.2k/45M)
- [x] LLM iteration counter
- [x] Thinking duration (≥2s)
- [x] Expand/collapse (Ctrl+O) for >3 tools
- [x] Background task support (Ctrl+B)

### Multi-Agent / Orchestration
- [x] Agent swarm panel (wave tracking, roles, status icons)
- [x] Per-agent tool count, token usage, current action
- [x] Collapse threshold (>5 agents)
- [x] Swarm SSE events (started, completed, failed)
- [x] Swarm completion terminates processing state

### Tasks & Plans
- [x] Task checklist from backend events
- [x] Live status tracking (pending/in_progress/completed/failed)
- [x] Plan review panel (approve/reject/edit)
- [x] Plan markdown rendering

### Signal Theory
- [x] Signal metadata on responses (Mode, Genre, Type, Format, Weight, Channel)
- [x] Signal badge in status bar

### Context Management
- [x] Context utilization bar (color by %)
- [x] Context pressure events from backend

### SSE
- [x] 19 event types handled
- [x] Exponential backoff reconnect (2s→30s cap, 10 attempts max)
- [x] 1MB buffer, keepalive handling
- [x] Intentional vs unintentional disconnect detection

---

## Pipeline Audit (2026-02-28)

**Backend emits 63+ system_event types. TUI handles 18 (28% coverage).**

The root cause: most backend modules omit `session_id` from Bus.emit calls, so events never reach the TUI's session-scoped SSE stream. The TUI also has ghost handlers for events the backend never emits.

### What works end-to-end (✓ emit → ✓ SSE → ✓ parse → ✓ display)
- Agent loop: `agent_response`, `llm_request`, `llm_response`, `tool_call`
- Context: `context_pressure`
- Swarm lifecycle: `swarm_started`, `swarm_completed`, `swarm_failed`

### Built but dead (✓ parse → ✓ handler → ✗ never receives data)
- **Orchestrator panel** (7 events): task_started/completed, wave_started, agent_started/progress/completed/failed — Agent.Orchestrator emits without `session_id`
- **Task checklist** (2 events): `task_created`/`task_updated` — backend never emits these names (emits `task_enqueued`/`task_completed` instead)

### Backend emits but TUI ignores (45+ events)
- Orchestrator (12 events) — no `session_id`
- Swarm Intelligence (6 events) — no `session_id`, no parser
- Pact workflows (9 events) — no `session_id`, no parser
- Budget/Treasury (13 events) — no `session_id`, no parser
- Learning (4 events) — no `session_id`, no parser
- Hook blocks (1 event) — no `session_id`, no parser
- Scheduler/Fleet (3 events) — no `session_id`, no parser

---

## Phase 2: Fix the Pipeline (CRITICAL)

### P0 — Unblock existing UI panels
These are fully built but receive no data. Fix = add `session_id` to backend emissions.

- [ ] **Orchestrator events**: Add `session_id` to 12 Bus.emit calls in `agent/orchestrator.ex` — unblocks the agents panel (BUG-013)
- [ ] **Task events**: Either rename TUI parsers to match backend (`task_enqueued` → `TaskCreatedEvent`) or add `task_created`/`task_updated` emissions — unblocks task checklist (BUG-012)
- [ ] **Hook blocked**: Add `session_id` to `hook_blocked` in `agent/hooks.ex` — user sees when security blocks actions (BUG-016)

### P1 — Wire up missing events
- [ ] `swarm_cancelled` + `swarm_timeout` SSE parsing (backend emits, TUI ignores) (BUG-001)
- [ ] `budget_warning` + `budget_exceeded` → system warnings in chat (BUG-015)
- [ ] Swarm intelligence rounds → progress display during debates (BUG-014)
- [ ] Plan detection via structured SSE event instead of string sniffing (BUG-003)

### P2 — Robustness
- [ ] Rate limit handling (429 detection + backoff) (BUG-007)
- [ ] Token refresh flow (endpoint exists, never called) (BUG-002)
- [ ] Error recovery suggestions (actionable hints after failures)
- [ ] Task list auto-clear on new orchestration (BUG-008)

### P3 — Wire up unused endpoints
- [ ] Complex orchestration (`POST /orchestrate/complex`) — needs UI trigger
- [ ] Real-time progress polling (`GET /orchestrate/:task_id/progress`) — SSE backup
- [ ] Signal classification (`POST /classify`) — standalone classify command

### P4 — UX Polish
- [ ] Chat search/filter (grep within conversation history)
- [ ] Copy-to-clipboard for messages
- [ ] Theme switching (dark/light)
- [ ] Split-pane view (chat + activity side-by-side)

### P5 — DevEx
- [ ] `--verbose` flag for debug SSE logging to file
- [ ] `--dry-run` flag for testing without backend
- [ ] Configurable keybindings (JSON config file)

---

## Phase 3: Advanced

- [ ] Embedded terminal (tool output rendering)
- [ ] Image rendering (sixel/kitty protocol for AI-generated images)
- [ ] Voice input/output integration
- [ ] Collaborative mode (multiple users, same session)
- [ ] Offline mode with local model fallback
- [ ] TUI → web bridge (share session as URL)

---

## API Coverage

### Endpoints Called (14/17)

| Endpoint | Status |
|----------|--------|
| `GET /health` | Active |
| `POST /api/v1/orchestrate` | Active |
| `GET /api/v1/commands` | Active |
| `POST /api/v1/commands/execute` | Active |
| `GET /api/v1/tools` | Active |
| `POST /api/v1/auth/login` | Active |
| `POST /api/v1/auth/logout` | Active |
| `POST /api/v1/auth/refresh` | Defined, never called |
| `POST /api/v1/classify` | Defined, never called |
| `GET /api/v1/sessions` | Active |
| `POST /api/v1/sessions` | Active |
| `GET /api/v1/sessions/:id` | Active |
| `GET /api/v1/models` | Active |
| `POST /api/v1/models/switch` | Active |
| `GET /api/v1/stream/:session_id` | Active (SSE) |
| `POST /api/v1/orchestrate/complex` | Defined, never called |
| `GET /api/v1/orchestrate/:task_id/progress` | Defined, never called |

### Backend Endpoints Not in TUI Client

| Endpoint | Notes |
|----------|-------|
| `POST /api/v1/swarm/launch` | Swarm launched via backend commands, not direct API |
| `GET /api/v1/swarm` | Could add /swarms command |
| `GET /api/v1/swarm/:id` | Could add /swarm <id> command |
| `DELETE /api/v1/swarm/:id` | Could add /swarm cancel <id> |
| `POST /api/v1/memory` | Memory save via backend commands |
| `GET /api/v1/memory/recall` | Memory recall via backend commands |
| `GET /api/v1/scheduler/jobs` | Scheduler via backend commands |
| `POST /api/v1/scheduler/reload` | Scheduler via backend commands |
| Fleet endpoints | Fleet management via backend commands |
| Event endpoints | Event system via backend commands |

---

## Build & Deploy

```bash
# Development
cd priv/go/tui && go run .

# Build for current platform
cd priv/go/tui && go build -o ../../../bin/osa .

# Cross-compile (all 4 targets)
bin/build-tui

# Verify
go build ./... && go vet ./...
```
