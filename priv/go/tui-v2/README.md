# OSA TUI v2

Terminal UI for the OSA (Operating System Agent) backend. Built on the Charm v2 stack.

## Stack

- **Go 1.24.2**
- `charm.land/bubbletea/v2` — TUI framework
- `charm.land/lipgloss/v2` — Styling
- `charm.land/bubbles/v2` — Components (viewport, textarea, key)
- `github.com/charmbracelet/glamour` — Markdown rendering

## Build

```bash
make build    # produces ./osa binary
make vet      # run go vet
make all      # vet + build
```

Or directly:

```bash
go build -o osa .
```

## Run

```bash
# Default — connects to http://localhost:8089
./osa

# Dev mode — uses port 19001 + dev profile
./osa --dev

# Named profile
./osa --profile staging

# Custom backend URL
OSA_URL=http://myhost:9000 ./osa
```

Or use `bin/osa` from the project root (starts the Elixir backend automatically):

```bash
bin/osa
bin/osa --dev
```

## First-Run Onboarding

On first launch (no `~/.osa/config.json`), the TUI presents an 8-step setup wizard:

```
Welcome → Profile → Template → Provider → API Key → Machines → Channels → Confirm
```

| Step | What it does |
|------|-------------|
| 1. Agent Name | Name your agent (default: "OSA") |
| 2. Profile | Your name + what you work on (optional, writes USER.md) |
| 3. Template | Select OS template or Blank (auto-discovers .osa-manifest.json) |
| 4. Provider | Pick from 18 LLM providers (Local/Cloud groups) |
| 5. API Key | Enter key (masked input, skipped for Ollama) |
| 6. Machines | Toggle skill groups: Communication, Productivity, Research |
| 7. Channels | Select messaging platforms: Telegram, WhatsApp, Discord, Slack |
| 8. Confirm | Review summary, write config files |

**Backend endpoints** (unauthenticated):
- `GET /onboarding/status` — check if setup needed + system info
- `POST /onboarding/setup` — write config + doctor health checks

Returning users skip onboarding entirely (zero overhead).

## Architecture

```
priv/go/tui-v2/
├── main.go                     Entry point (flags, profile, theme detection)
├── go.mod                      charm.land/* v2 dependencies
│
├── app/
│   ├── app.go                  Root model: Init, Update (60+ handlers), View
│   ├── state.go                12 app states (incl. StateOnboarding)
│   ├── keys.go                 22 key bindings
│   └── layout.go               Responsive layout (compact vs sidebar)
│
├── ui/                         All UI components
│   ├── header/                 Compact header bar
│   ├── chat/                   Message list + items + thinking box + markdown
│   ├── tools/                  14 per-tool renderers (bash, file, search, web, mcp, ...)
│   ├── sidebar/                Toggleable sidebar (files, model, context)
│   ├── activity/               Timer, tool feed, agent tracker, tasks, phrases
│   ├── input/                  Multi-line textarea with history
│   ├── completions/            Command completions popup
│   ├── status/                 Bottom bar (signal, tokens, context) + pills
│   ├── dialog/                 Stacking modals (picker, palette, plan, permissions, onboarding, ...)
│   ├── toast/                  Notification overlay
│   ├── diff/                   Inline diff + syntax highlighting
│   ├── anim/                   Gradient animated spinner
│   ├── logo/                   ASCII art logo with gradient rendering
│   ├── selection/              Mouse text selection
│   ├── clipboard/              OSC52 + native clipboard
│   ├── image/                  Kitty/iTerm2/Sixel image rendering
│   ├── attachments/            File attachment chips
│   ├── list/                   Reusable virtual list
│   └── common/                 Shared helpers (highlight, scrollbar, keybinds, OS)
│
├── client/                     Backend communication
│   ├── http.go                 34 REST methods (all backend endpoints + onboarding)
│   ├── sse.go                  SSE streaming + reconnect (33 event types)
│   └── types.go                Request/response structs
│
├── msg/                        All tea.Msg types
├── style/                      Colors, styles, themes, gradients
└── config/                     Config persistence (~/.osa/tui.json)
```

## Backend Integration

### SSE Events (33 types)

The TUI opens a persistent SSE connection to `/api/v1/stream/{session_id}` on startup.
All events are parsed in `client/sse.go` and dispatched as typed `tea.Msg` values.

Top-level: `connected`, `agent_response`, `tool_call`, `llm_request`, `llm_response`,
`streaming_token`, `tool_result`, `signal_classified`, `system_event`

System events (24): orchestrator lifecycle, swarm lifecycle, thinking deltas,
context pressure, task CRUD, hook/budget notifications, swarm intelligence rounds.

### HTTP Client (34 methods)

Every backend endpoint has a corresponding client method in `client/http.go`:

- **Core**: Health, Orchestrate, ListTools, ListCommands, ExecuteCommand
- **Auth**: Login, RefreshToken, Logout
- **Sessions**: List, Create, Get, GetMessages
- **Models**: List, Switch
- **Classification**: Classify
- **Tools**: ExecuteTool
- **Skills**: List, Create
- **Orchestration**: LaunchComplex, GetProgress, ListTasks
- **Swarm**: Launch, List, GetStatus, Cancel
- **Memory**: Save, Recall
- **Analytics**: Get
- **Scheduler**: ListJobs, Reload
- **Machines**: List
- **Onboarding**: CheckOnboarding, CompleteOnboarding

### Command Routing

Locally-handled: `/help`, `/clear`, `/exit`, `/login`, `/logout`, `/sessions`, `/session`,
`/models`, `/model`, `/theme`, `/bg`

Everything else falls through to `POST /api/v1/commands/execute` — giving access to all
93+ backend slash commands.

## Key Bindings

| Key | Action |
|-----|--------|
| Enter | Submit message |
| Alt+Enter | Insert newline |
| Ctrl+C | Cancel / quit |
| Ctrl+D | Quit (EOF) |
| Ctrl+L | Toggle sidebar |
| Ctrl+K | Command palette |
| Ctrl+N | New session |
| Ctrl+O | Expand/collapse details |
| Ctrl+T | Toggle thinking box |
| Ctrl+B | Move task to background |
| Ctrl+U | Clear input |
| F1 | Help |
| Home/End | Scroll top/bottom |
| PgUp/PgDn | Page scroll |
| j/k | Line scroll (when input empty) |
| u/d | Half-page scroll (when input empty) |
| y/c | Copy last message |
| Tab | Autocomplete commands |
| Up/Down | Input history |
| Esc | Cancel / dismiss |

## Themes

4 built-in themes: `dark` (default), `light`, `catppuccin`, `tokyo-night`

Switch with `/theme <name>` or cycle via command palette.

## Stats

- 68 files, ~19,270 lines of Go
- 23MB binary
- 52+ UI components
- 14 per-tool renderers
