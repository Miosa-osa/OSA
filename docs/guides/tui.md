# TUI User Guide

> Terminal User Interface for OSA — a Bubble Tea-powered interactive agent terminal

## Quick Start

```bash
# Start the backend
OSA_MODEL=qwen3:8b mix osa.serve

# In another terminal, launch the TUI
cd priv/go/tui && ./osa
```

Or use the one-command launcher:

```bash
bin/osa
```

---

## States

The TUI operates as a state machine:

| State | Description | Exit |
|-------|-------------|------|
| **Connecting** | Waiting for backend health check | Automatic on success |
| **Banner** | 2-second startup splash screen | Automatic or any keypress |
| **Idle** | Ready for input | Type message or command |
| **Processing** | Agent is working | Ctrl+C to cancel |
| **Plan Review** | Reviewing agent plan | a=approve, r=reject, e=edit |
| **Model Picker** | Browsing models | Arrow keys + Enter, Esc to cancel |
| **Palette** | Command palette overlay | Type to filter, Enter to select |

---

## Keyboard Shortcuts

| Key | Idle | Processing | Plan Review |
|-----|------|------------|-------------|
| **Enter** | Send message | — | — |
| **Ctrl+C** | Quit (double-press) | Cancel request | — |
| **Ctrl+D** | Quit (empty input) | — | — |
| **Ctrl+K** | Command palette | — | — |
| **Ctrl+N** | New session | — | — |
| **Ctrl+U** | Clear input line | — | — |
| **Esc** | Clear input | Cancel request | — |
| **Tab** | Cycle command completions | — | — |
| **Up/Down** | History navigation | — | — |
| **PgUp/PgDn** | Scroll chat | Scroll chat | — |
| **Mouse wheel** | Scroll chat | Scroll chat | — |
| **Home** | Scroll to top | — | — |
| **End** | Scroll to bottom | — | — |
| **Ctrl+E** | — | Toggle activity detail | — |
| **Ctrl+B** | — | Background task | — |

---

## Slash Commands

### Local Commands (handled in TUI)

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/clear` | Clear chat history |
| `/exit` or `/quit` | Exit OSA |
| `/models` | Open interactive model picker |
| `/model` | Show current provider / model |
| `/model <provider>` | Open picker filtered to provider |
| `/model <provider>/<name>` | Switch model directly |
| `/model <name>` | Switch Ollama model (default) |
| `/theme` | List available themes |
| `/theme <name>` | Switch theme (persisted) |
| `/sessions` | List saved sessions |
| `/session` | Show current session ID |
| `/session new` | Create new session |
| `/session <id>` | Switch to session (loads history) |
| `/login <user_id>` | Authenticate with backend |
| `/logout` | Log out |
| `/bg` | List background tasks |

### Backend Commands (forwarded to API)

All other `/` commands are sent to the backend via `POST /api/v1/commands/execute`. Examples:

| Command | Description |
|---------|-------------|
| `/status` | System status |
| `/agents` | List agent roster |
| `/tiers` | Show tier configuration |
| `/swarms` | List swarm presets |
| `/hooks` | Show hook pipeline |
| `/memory` | Show memory info |
| `/compact` | Compact conversation context |
| `/usage` | Token usage stats |
| `/budget` | Budget status |
| `/prime` | Load priming context |

See `docs/reference/cli.md` for the full 88-command reference.

---

## Model Selection

### Interactive Picker

Type `/models` to open the model picker:

```
◈ Select Model  ↑↓ navigate · Enter select · Esc cancel

  ollama
  > ● qwen3:8b  4.9 GB  active
    ○ qwen3:32b  19.1 GB
    ○ llama3.2:latest  2.0 GB

  anthropic
    ○ claude-sonnet-4-20250514

  3 model(s) available
```

- Arrow keys or **mouse wheel** navigate, wrapping at edges
- Enter selects, Esc cancels
- Active model marked with `●`
- Size shown for Ollama models
- Grouped by provider
- **Mouse scroll** works in both chat and picker

### Direct Switch

```bash
/model qwen3:32b           # Ollama model (default provider)
/model anthropic/claude-3   # Explicit provider/name
/model anthropic            # Open picker filtered to anthropic models
/model                      # Show "Current: ollama / qwen3:8b"
```

18 providers recognized: ollama, anthropic, openai, groq, together, fireworks, deepseek, perplexity, mistral, replicate, openrouter, google, cohere, qwen, moonshot, zhipu, volcengine, baichuan.

---

## Themes

```bash
/theme                # List available themes
/theme catppuccin     # Switch theme (auto-saved to ~/.osa/tui.json)
```

Theme persists across restarts. Available themes depend on the build.

---

## Command Palette (Ctrl+K)

Press **Ctrl+K** to open a fuzzy-searchable command palette:

- Type to filter commands
- Arrow keys to navigate
- Enter to execute
- Esc to dismiss

Commands are sourced from both local TUI commands and the backend's command registry.

---

## Sessions

Sessions persist conversation history on the backend.

```bash
/sessions        # List all saved sessions (shows ID + title)
/session new     # Start fresh session
/session abc123  # Resume session (loads chat history)
```

When switching sessions, the TUI loads prior messages so you can see the conversation context.

---

## Real-Time Activity Display

During processing, the TUI shows:

- **Activity panel** — tool calls with name, duration, success/failure
- **Tool results** — truncated preview of tool return values
- **Token streaming** — live response text as the LLM generates
- **Signal badge** — real-time Signal classification (mode/genre)
- **Agent panel** — multi-agent wave progress (when orchestrating)
- **Task tracker** — task creation/completion events

Press **Ctrl+E** to expand/collapse the activity detail.

---

## Toast Notifications

Non-blocking notifications appear briefly for:
- Theme changes
- Background task moves
- SSE parse warnings
- Budget warnings

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OSA_URL` | `http://localhost:8089` | Backend URL |
| `OSA_TOKEN` | — | Pre-set auth token |

### Config File

Settings persist in `~/.osa/tui.json`:

```json
{
  "theme": "catppuccin",
  "default_model": "qwen3:8b",
  "backend_url": ""
}
```

### Profile Directory

```
~/.osa/
├── profiles/
│   └── default/
│       ├── token           # JWT auth token
│       └── refresh_token   # JWT refresh token
└── tui.json                # TUI settings
```

---

## Authentication

### Dev Mode (default)

No authentication required. All requests pass through as "anonymous".

### Production Mode

```bash
/login myuser          # Authenticate
```

Tokens are saved to the profile directory. Auto-refresh happens transparently when the JWT expires — the refresh token is used automatically, no manual re-login needed.

---

## Architecture

```
┌──────────────┐     HTTP/SSE     ┌──────────────┐
│   Go TUI     │ ◄──────────────► │ Elixir       │
│  (Bubble Tea)│                  │ Backend      │
│              │  POST /orchestrate│ (Bandit)     │
│  Input ──────┼──────────────────┼─► Agent.Loop  │
│              │                  │    ↓          │
│  Chat ◄──────┼──────────────────┼── SSE Stream  │
│  Activity    │  GET /stream/:id │    ↓          │
│  Status      │                  │  Events.Bus   │
│  Banner      │                  │  Bridge.PubSub│
└──────────────┘                  └──────────────┘
```

### SSE Events Handled

| Event | Display |
|-------|---------|
| `streaming_token` | Live text in chat |
| `agent_response` | Final response with signal |
| `tool_call` (start/end) | Activity panel |
| `tool_result` | Truncated preview in chat |
| `signal_classified` | Status bar signal badge |
| `llm_request` | Iteration counter |
| `llm_response` | Token usage stats |
| `context_pressure` | Context bar percentage |
| `swarm_*` | Swarm lifecycle messages |
| `orchestrator_*` | Agent panel updates |
| `task_*` | Task tracker updates |
| `hook_blocked` | Error message |
| `budget_*` | Warning/error messages |

---

## Troubleshooting

### Backend unreachable
TUI retries every 5 seconds. Check that the backend is running on the expected port.

### SSE disconnects
Auto-reconnects up to 10 times with exponential backoff. If exhausted, restart the TUI.

### Auth expired
Auto-refresh triggers automatically. If refresh also fails, use `/login` to re-authenticate.

### Large responses
Responses over 100KB are truncated. SSE buffer is 1MB per event.
