# OSA Gap Tracker

> Full audit: 2026-02-28 | Tracks every known issue across TUI + Backend

## Status Key
- `[ ]` Open | `[~]` In Progress | `[x]` Done | `[-]` Won't Fix

---

## CRITICAL — Broken or Blocks Core UX

| # | Issue | Component | Files | Status |
|---|-------|-----------|-------|--------|
| C1 | **No per-token SSE streaming** — `Agent.Loop` now uses `llm_chat_stream/3`. Token deltas emitted as `streaming_token` system events via Bus. TUI accumulates and renders live. | Backend + TUI | `agent/loop.ex`, `client/sse.go` | `[x]` |
| C2 | **No CORS middleware** — Added `cors_headers` plug + OPTIONS preflight handler. | Backend | `channels/http.ex` | `[x]` |
| C3 | **No rate limiting** — all API endpoints unthrottled. Needs custom plug or dependency. | Backend | `channels/http.ex` | `[ ]` |
| C4 | **No request body size cap** — Added `length: 1_000_000` to Plug.Parsers. | Backend | `channels/http/api.ex` | `[x]` |
| C5 | **SSE parse errors invisible** — Replaced `fmt.Fprintf(os.Stderr, ...)` with `SSEParseWarning` events → toast notifications. | TUI | `client/sse.go` | `[x]` |
| C6 | **StateBanner unreachable** — Fixed: `handleHealth` now sets `StateBanner` + 2s timer. | TUI | `app/app.go` | `[x]` |
| C7 | **Auth login has no identity verification** — `POST /auth/login` issues JWT for any user_id string. No password, no SSO. | Backend | `channels/http/api.ex` | `[-]` dev-mode OK |

---

## MAJOR — Missing Core Features

| # | Issue | Component | Files | Status |
|---|-------|-----------|-------|--------|
| M1 | **JWT auto-refresh** — Added `RefreshToken()` client method, auto-refresh on SSE auth failure, refresh token saved to profile. | TUI | `client/http.go`, `app/app.go`, `main.go` | `[x]` |
| M2 | **Session history loaded on switch** — `switchSession` now fetches messages via embedded or `/messages` endpoint, replays into chat. | TUI | `app/app.go` | `[x]` |
| M3 | **Tool result content displayed** — `tool_result` SSE events show truncated preview (200 chars) in chat. | TUI | `app/app.go`, `model/activity.go` | `[x]` |
| M4 | **`signal_classified` rendered real-time** — New SSE case updates status bar signal badge live during generation. | TUI | `client/sse.go`, `app/app.go` | `[x]` |
| M5 | **`tool_result` events wired** — New `ToolResultEvent` type parsed from SSE, forwarded to activity + chat. | TUI | `client/sse.go`, `app/app.go` | `[x]` |
| M6 | **Cancel (Ctrl+C/Esc) doesn't stop backend** — TUI sets idle but backend continues processing. Needs cancel API endpoint. | TUI + Backend | `app/app.go` | `[ ]` |
| M7 | **Swarm launch not exposed in TUI** — SSE events handled but no `/swarm <pattern>` command. Passthrough via `/swarm` backend command works. | TUI | `app/app.go` (submitInput) | `[ ]` |
| M8 | **Memory endpoints not wired** — Works via command passthrough (`/mem-save`, `/mem-search`). Direct API integration deferred. | TUI | `client/http.go` | `[-]` passthrough OK |
| M9 | **Theme persisted** — `/theme <name>` saves to `~/.osa/tui.json`, loaded on startup. | TUI | `config/config.go`, `app/app.go` | `[x]` |
| M10 | **TUI config file added** — `config/config.go` package: theme, default_model, backend_url in `~/.osa/tui.json`. | TUI | `config/config.go` | `[x]` |
| M11 | **Global error handler added** — `call/2` override with rescue → structured JSON 500 + Logger.error. | Backend | `channels/http/api.ex` | `[x]` |
| M12 | **`Skills.Registry` not started** — `application.ex` doesn't start it. 8 `Skills.Builtins` modules unreachable. Dead code. | Backend | `application.ex`, `skills/` | `[ ]` |
| M13 | **`Swarm.Intelligence` and `Swarm.PACT` not exposed** — implemented but no HTTP endpoints and no path for external invocation. | Backend | `swarm/intelligence.ex`, `swarm/pact.ex` | `[ ]` |
| M14 | **HTTP.ex docstring severely out of date** — documents ~12 endpoints; actual API surface is 40+. | Backend | `channels/http.ex` | `[ ]` |
| M15 | **`contacts` and `conversations` tables orphaned** — migrations create tables, no Ecto schemas or runtime code uses them. | Backend | `store/`, migrations | `[ ]` |
| M16 | **`chat_stream/3` only on Anthropic** — all 17 other providers fall back to synchronous. | Backend | `providers/` | `[ ]` |
| M17 | **`OrchestrateComplex`, `Progress`, `Classify` defined but never called** — dead client code. | TUI | `client/http.go:63,79,149` | `[ ]` |
| M18 | **Matrix webhook is a stub** — `POST /channels/matrix/webhook` does nothing. | Backend | `channels/http/api.ex:1171` | `[ ]` |
| M19 | **Session CRUD endpoints missing** — TUI calls GET/POST /sessions, GET /sessions/:id, GET /sessions/:id/messages but backend had none. Added all 4 routes using Memory.list_sessions + Memory.load_session + SDK.Session.create. | Backend | `channels/http/api.ex` | `[x]` |

---

## MINOR — Polish & Nice-to-Have

| # | Issue | Component | Status |
|---|-------|-----------|--------|
| m1 | `StatePlanReview` has no scrollable viewport — long plans overflow terminal | TUI | `[ ]` |
| m2 | Tab completion shows no candidate list — blind cycling through commands | TUI | `[ ]` |
| m3 | No message timestamps rendered (`ChatMessage.Timestamp` stored but unused) | TUI | `[ ]` |
| m4 | No scroll position indicator in chat viewport | TUI | `[ ]` |
| m5 | Context bar warning thresholds (75% vs CLAUDE.md spec 85%) | TUI | `[ ]` |
| m6 | `extractResumeSessionID` fragile manual string parsing of Elixir tuples | TUI | `[ ]` |
| m7 | SSE scanner 1MB buffer limit — oversized events dropped on disconnect | TUI | `[ ]` |
| m8 | `charLimit: 4096` not communicated to user (no visible counter) | TUI | `[ ]` |
| m9 | Session list missing creation timestamp display | TUI | `[ ]` |
| m10 | `prime-businessos` command referenced in CLAUDE.md but not registered | Backend | `[ ]` |
| m11 | Signal webhook has no signature verification | Backend | `[ ]` |
| m12 | Security headers not applied inside `/api/v1` (only outer router) | Backend | `[ ]` |
| m13 | `tool_result` event type never emitted (registered but no `Bus.emit` call) | Backend | `[ ]` |
| m14 | Rust NIF disabled by default — token counting uses heuristic always | Backend | `[ ]` |
| m15 | No test coverage for HTTP API routes | Backend | `[ ]` |
| m16 | `POST /auth/logout` stateless — no token invalidation | Backend | `[ ]` |
| m17 | `Memory.recall/0` unbounded — returns full MEMORY.md with no pagination | Backend | `[ ]` |
| m18 | `io.ReadFull(rand.Reader, b)` — Fixed with proper error handling + fallback bytes | TUI | `[x]` |
| m19 | `handleCommandAction` silently no-ops unknown action strings | TUI | `[ ]` |
| m20 | 47 duplicate backup files (`* 2.md`, `* 3.md`) cluttering docs/ | Docs | `[ ]` |
| m21 | **No loading state during `/models` fetch** — input stays focused, user can interleave. Fixed: blur input + toast. | TUI | `[x]` |
| m22 | **No "Switching..." feedback for `/model <name>`** — direct switch silent until done. Fixed: system message. | TUI | `[x]` |
| m23 | **Backend passthrough commands have no loading indicator** — silent wait. Fixed: toast notification. | TUI | `[x]` |
| m24 | **`/sessions` has no loading indicator** — silent async. Fixed: toast notification. | TUI | `[x]` |
| m25 | **`/login` has no loading indicator** — silent async. Fixed: toast "Authenticating..." | TUI | `[x]` |
| m26 | **`/logout` has no loading indicator** — silent async. Fixed: toast "Logging out..." | TUI | `[x]` |
| m27 | **`/session new` has no loading indicator** — silent async. Fixed: toast "Creating session..." | TUI | `[x]` |
| m28 | **`/session <id>` has no loading indicator** — silent async. Fixed: toast "Switching to session..." | TUI | `[x]` |

---

## Documentation Gaps

| # | Gap | Status |
|---|-----|--------|
| D1 | TUI user guide created: `docs/guides/tui.md` — keyboard shortcuts, commands, architecture, SSE events, config | `[x]` |
| D2 | HTTP API docs list ~12 endpoints; actual surface is 40+. API.ex docstring already complete. | `[ ]` |
| D3 | No per-agent documentation (22+ agents not catalogued) | `[ ]` |
| D4 | No skills registry/inventory doc | `[ ]` |
| D5 | No swarm preset gallery (10 presets mentioned but not documented) | `[ ]` |
| D6 | CLI reference updated with `/models`, `/model <provider>/<model>`, `/theme` commands | `[x]` |
| D7 | Architecture SDK doc (`docs/architecture/sdk.md`) at 50K — needs trimming | `[ ]` |

---

## Priority Execution Order

1. ~~**Streaming** (C1)~~ — DONE: `llm_chat_stream/3` in agent loop, `streaming_token` SSE events
2. ~~**Middleware** (C2+C4+M11)~~ — DONE: CORS, body cap, error handler. C3 (rate limiting) still open.
3. ~~**Tool results + signal events** (M3+M4+M5)~~ — DONE: `tool_result` + `signal_classified` wired in TUI
4. ~~**Auth lifecycle** (M1)~~ — DONE: auto-refresh + refresh token persistence
5. ~~**Session history** (M2)~~ — DONE: loads messages on session switch
6. ~~**TUI config** (M9+M10)~~ — DONE: `~/.osa/tui.json` with theme persistence
7. **Cancel propagation** (M6) — OPEN: needs backend cancel endpoint
8. ~~**Dead code cleanup** (C6)~~ — DONE: StateBanner + errcheck fixed
9. ~~**Docs** (D1+D6)~~ — DONE: TUI guide + CLI reference updated
10. **Remaining** — C3 (rate limiting), M6 (cancel), M7 (swarm cmd), M12-M18, m1-m20, D2-D5
