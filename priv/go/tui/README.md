# OSA TUI

Terminal UI for the Optimal System Agent, built with [Bubble Tea](https://github.com/charmbracelet/bubbletea).

Connects to the Elixir OSA backend over HTTP and SSE to provide a full interactive
terminal session: streaming tool call activity, multi-agent swarm visibility, task
checklists, plan review, and Signal Theory metadata on every response.

---

## Quick Start

From the project root — one command, one terminal:

```bash
bin/osa                # builds TUI on first run, starts backend, launches TUI
bin/osa --dev          # dev profile + port 19001
```

The wrapper script handles everything: backend lifecycle, health check, cleanup on exit.

---

## Manual Setup

If you prefer to manage the backend separately:

```bash
# Terminal 1: Start the backend
mix osa.serve          # or: osagent serve

# Terminal 2: Build and run
cd priv/go/tui
make build             # produces ./osa
./osa                  # connects to http://localhost:8089

# Override backend URL and/or pre-set an auth token
OSA_URL=http://localhost:9000 OSA_TOKEN=<jwt> ./osa

# Install to PATH
make install           # copies ./osa to $GOPATH/bin or /usr/local/bin
```

---

## CLI Flags

| Flag | Default | Description |
|---|---|---|
| `--profile <name>` | — | Named profile; isolates state to `~/.osa/profiles/<name>/` |
| `--dev` | `false` | Alias for `--profile dev`; also defaults URL to `http://localhost:19001` |
| `--no-color` | `false` | Disable ANSI color output |
| `--version`, `-V` | — | Print version and exit |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OSA_URL` | `http://localhost:8089` | Backend base URL |
| `OSA_TOKEN` | — | JWT token; skips the `/login` step if set |

---

## Auth

The TUI uses JWT bearer tokens issued by the backend.

### Login

```
/login [user_id]
```

Calls `POST /api/v1/auth/login`. On success, the token is persisted to
`~/.osa/profiles/<name>/token` (or `~/.osa/token` when no profile is set) and
automatically applied to all subsequent requests and the SSE stream.

### Logout

```
/logout
```

Calls `POST /api/v1/auth/logout`, clears the in-memory token, and removes the
persisted token file.

### Auto-401 detection

The SSE stream monitors for HTTP 401/403 responses. On detection it disconnects,
displays `"Authentication expired. Use /login to re-authenticate."`, and returns
the UI to idle so you can re-authenticate without restarting.

### Token persistence path

```
~/.osa/profiles/<name>/token   # with --profile <name>
~/.osa/token                   # default (no profile)
```

At startup, if `OSA_TOKEN` is not set, the TUI reads the persisted token from the
profile directory automatically.

---

## Slash Commands

Commands are dispatched client-side (built-in) or forwarded to the backend via
`POST /api/v1/commands/execute`. Tab-completion is available after typing `/`.

| Command | Description |
|---|---|
| `/login [id]` | Authenticate with the backend |
| `/logout` | End session and clear token |
| `/status` | System status |
| `/model` | Current provider / model |
| `/model <provider>` | Open picker filtered to provider (18 recognized) |
| `/model <provider>/<name>` | Direct model switch |
| `/models` | List available models |
| `/agents` | List agent roster |
| `/tools` | List available tools |
| `/usage` | Token usage breakdown |
| `/compact` | Trigger context compaction |
| `/clear` | Clear chat history |
| `/help` | Show command reference |
| `/theme [name]` | List or switch themes (dark, light, catppuccin) |
| `/exit`, `/quit` | Exit OSA |

---

## Architecture

```
main.go              Entry point — flag parsing, profile resolution, theme auto-detect
app/
  app.go             Root Model; message routing, SSE lifecycle, auth, command dispatch
  state.go           State machine: 7 states (Connecting → Banner → Idle ↔ Processing ↔ PlanReview ↔ ModelPicker ↔ Palette)
  keymap.go          All key bindings via charmbracelet/bubbles/key
client/
  http.go            REST client (health, orchestrate, tools, commands, auth)
  sse.go             SSE streaming client with exponential backoff reconnect (max 30s)
  types.go           Request/response DTOs and Signal struct
model/
  activity.go        Tool call feed + token counter + elapsed timer
  agents.go          Multi-agent swarm progress + wave tracking
  banner.go          Startup header (version, provider, tool count, uptime)
  chat.go            Scrollable message viewport (user / agent / system / streaming)
  input.go           Text input with history navigation and command autocomplete
  palette.go         Command palette overlay (Ctrl+K) with fuzzy filtering
  picker.go          Model selector UI
  plan.go            Plan review panel (approve / reject / edit)
  status.go          Signal metadata bar + context utilization bar
  tasks.go           Task checklist with live status icons
  toast.go           Toast notification queue (auto-dismiss, max 3 visible)
msg/
  msg.go             All tea.Msg types (import-cycle-free hub)
style/
  style.go           Lipgloss color palette, component styles, and SetTheme() API
  themes.go          Theme definitions (dark, light, catppuccin)
markdown/
  render.go          Glamour-based ANSI markdown renderer
```

### State machine

```
Connecting  →  Banner  →  Idle  ↔  Processing  ↔  PlanReview
                                ↔  ModelPicker
                                ↔  Palette
```

| State | Trigger |
|---|---|
| `Connecting` | Startup; retries health check every 5 s until backend responds |
| `Banner` | Health check succeeded; shows startup header |
| `Idle` | Ready for input; any key dismisses banner |
| `Processing` | User submitted a message; waiting for agent response |
| `PlanReview` | Agent response contains a `## Plan` block; prompts approve/reject/edit |
| `ModelPicker` | `/models` command opens the model selector |
| `Palette` | `Ctrl+K` opens the command palette overlay |

---

## SSE Event Flow

The TUI opens a persistent SSE connection to `/api/v1/stream/{session_id}` immediately
after the health check succeeds. All real-time updates arrive over this stream.

| SSE Event | Subtype / Phase | What the TUI does |
|---|---|---|
| `connected` | — | Records session ID |
| `llm_request` | — | Updates activity spinner with iteration count |
| `llm_response` | — | Records token usage and duration; updates status bar |
| `tool_call` | `start` | Adds entry to activity feed |
| `tool_call` | `end` | Marks entry complete with duration |
| `agent_response` | — | Renders final output; shows Signal metadata |
| `system_event` | `orchestrator_task_started` | Activates agent swarm panel |
| `system_event` | `orchestrator_wave_started` | Updates wave counter |
| `system_event` | `orchestrator_agent_started` | Adds agent row to swarm panel |
| `system_event` | `orchestrator_agent_progress` | Updates agent tool/token counts |
| `system_event` | `orchestrator_agent_completed` | Marks agent done |
| `system_event` | `orchestrator_task_completed` | Hides swarm panel |
| `system_event` | `context_pressure` | Updates context utilization bar |
| `streaming_token` | — | Accumulates partial response; renders inline (TUI-ready, backend pending) |
| `system_event` | `hook_blocked` | Shows warning toast |
| `system_event` | `budget_warning` | Shows budget warning toast |
| `system_event` | `budget_exceeded` | Shows budget exceeded error |
| `system_event` | `swarm_cancelled` | Shows cancellation notice |
| `system_event` | `swarm_timeout` | Shows timeout warning |

The SSE client reconnects automatically on unexpected disconnects using exponential
backoff (2 s, 4 s, 8 s … capped at 30 s). Intentional closes (logout, quit) do not
trigger reconnect.

---

## Display Reference

### Activity panel (during Processing)

Shown below the chat viewport while the agent is running. Displays elapsed time,
tool count, and a scrollable feed of tool invocations.

```
⏺ Reasoning… (8s · 2 tools · ↓ 4.2k · thought for 3s)
  ├─ file_read   Reading lib/agent/loop.ex          (120ms)
  └─ shell_execute  Running mix test                (running…)
     +12 more (ctrl+o to expand)
     ctrl+b to run in background
```

### Agent swarm panel (during multi-agent tasks)

Appears when an `orchestrator_task_started` event arrives. Tracks each agent's
progress across waves.

```
  Running 3 agents… (ctrl+o to expand)
   ├─ researcher · 14 tool uses · 70.8k tokens
   │  ⎿  Searching for 4 patterns, reading 10 files…
   ├─ builder · 20 tool uses · 69.0k tokens
   │  ⎿  Done
   └─ tester · 27 tool uses · 66.1k tokens
      ⎿  Running tests…
```

### Task checklist

Populated by the backend when the agent emits a task list. Persists across the
Processing → Idle transition.

```
  ⎿  ✔ Phase 1: Add fleet methods
     ◼ Phase 2: Strip orchestration code
     ◻ Phase 3: Update go.mod and verify builds
```

Icons: `✔` complete, `◼` in-progress, `◻` pending.

### Status bar

Always visible at the bottom. Shows Signal Theory metadata after each response
and a context utilization bar when context pressure events arrive.

```
  [Linguistic · Spec · Direct · Markdown]  context 42%  ████░░░░░░
```

---

## Key Bindings

| Key | Context | Action |
|---|---|---|
| `Enter` | Idle | Submit input |
| `Alt+Enter` | Idle | Insert newline (multi-line input, up to 6 lines) |
| `Ctrl+C` | Idle | Confirm-quit prompt (double-tap to exit) |
| `Ctrl+C` | Processing | Cancel current request |
| `Ctrl+D` | Idle (empty input) | Quit immediately |
| `Ctrl+K` | Idle | Open command palette |
| `Ctrl+O` | Processing | Expand / collapse tool detail feed |
| `Ctrl+B` | Processing | Move task to background; return to input |
| `Tab` | Idle (after `/`) | Autocomplete command name |
| `Up / Down` | Idle | Navigate input history |
| `Up / Down` | Palette | Navigate commands |
| `Mouse wheel` | Idle / Processing | Scroll chat viewport or picker |
| `PgUp / PgDn` | Processing | Scroll chat viewport |
| `Enter` | Palette | Execute selected command |
| `Esc` | Palette | Dismiss palette |
| `Esc` | Any | Cancel current action |

---

## Theme System

The TUI ships with 3 built-in themes and auto-detects your terminal background at startup.

| Theme | Description |
|---|---|
| `dark` | Default — violet/cyan accents on dark backgrounds |
| `light` | Darker accents (violet-700, cyan-600) for white/light terminals |
| `catppuccin` | Mocha palette — mauve, sky, green, yellow, red |

```
/theme               # list available themes
/theme catppuccin    # switch to catppuccin
```

Auto-detection uses `lipgloss.HasDarkBackground()` — if your terminal reports a light
background, the `light` theme is applied automatically. Override any time with `/theme`.

---

## Command Palette

Press `Ctrl+K` to open the command palette — a fuzzy-searchable overlay of all
available commands (both local and backend).

```
┌──────────────────────────────────────────┐
│  Command Palette                         │
│  ┌────────────────────────────────────┐  │
│  │ search…                            │  │
│  └────────────────────────────────────┘  │
│  > /agents   List agent roster    [cmd]  │
│    /clear    Clear chat history    [cmd]  │
│    /help     Show command ref      [cmd]  │
│    /models   List available models [cmd]  │
│    /theme    Switch theme          [cmd]  │
│    …                                     │
│                                          │
│  ↑↓ navigate · enter select · esc close  │
└──────────────────────────────────────────┘
```

Type to filter, arrow keys to navigate, Enter to execute, Esc to dismiss.

---

## Toast Notifications

Transient feedback messages appear right-aligned above the input area and auto-dismiss
after 4 seconds. Up to 3 toasts stack simultaneously.

```
                                    ✓ Theme set to: catppuccin
                                    ⚠ Task moved to background
```

Toasts are used for confirmations (theme switch, session created, background task)
while persistent messages (errors, agent responses) remain in the chat scrollback.

---

## Profiles

Profiles isolate all persisted state (token, history) to a named directory.

```bash
./osa --profile dev      # state in ~/.osa/profiles/dev/
./osa --profile staging  # state in ~/.osa/profiles/staging/
./osa --dev              # shorthand for --profile dev + URL http://localhost:19001
```

Profile directory layout:

```
~/.osa/profiles/<name>/
  token        JWT token (mode 0600, written by /login, read at startup)
```

Without a profile flag, state is stored directly in `~/.osa/`.

---

## Cross-Compilation

```bash
make cross
```

Produces four statically-linked binaries in the current directory:

| Binary | Target |
|---|---|
| `osa-darwin-arm64` | macOS Apple Silicon |
| `osa-darwin-amd64` | macOS Intel |
| `osa-linux-amd64` | Linux x86-64 |
| `osa-linux-arm64` | Linux ARM64 |

All binaries have debug info stripped (`-s -w`) and embed the version string from
the nearest git tag (`git describe --tags --always --dirty`).

```bash
make clean    # remove ./osa and all ./osa-* binaries
```
