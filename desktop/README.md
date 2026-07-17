# OSA Desktop

> **Legacy / experimental (WIP).** This desktop GUI is not part of the shipped
> OSA agent and is not actively maintained. The supported way to run OSA is the
> terminal app — see the main [README](../README.md). Kept here for future work.

> Your AI agent, running locally on your machine.

OSA Desktop is the native GUI for [OSA](https://github.com/Miosa-osa/OptimalSystemAgent) — an Elixir/OTP AI agent platform. It runs on your machine, connects to a local OSA backend, and gives you full control over multi-agent orchestration, 18 LLM providers, memory, scheduling, and knowledge graphs. No cloud required.

**Built with:** Tauri v2 + SvelteKit 2 + Svelte 5 | Dark glassmorphic UI | <10MB shell

---

## Install & Run

### Prerequisites

- **Elixir** 1.17+ / OTP 27+ — the OSA backend
- **Node.js** 22+ — the desktop frontend
- **Rust** 1.75+ — only needed for native Tauri builds

### One Command (recommended)

From the project root:

```bash
./dev.sh               # Starts backend (:9089) + frontend (:5199) together
./dev.sh --tauri       # Same, but opens as a native Tauri window
```

Open **http://localhost:5199** and you're in.

### Manual Setup

```bash
# 1. Backend
mix deps.get
mix osa.serve                    # Elixir backend on :9089

# 2. Frontend (separate terminal)
cd desktop
npm install
npm run dev                      # Browser mode on :5199
npm run tauri:dev                # Or native desktop mode
```

### Production Build

```bash
cd desktop
npm run tauri:build              # .dmg / .msi / .AppImage
```

---

## Architecture

```
OSA Desktop (Tauri v2 shell, <10MB)
  |
  |  SvelteKit 2 + Svelte 5 (static SPA, system WebView)
  |
  |  HTTP + SSE
  v
OSA Backend (Elixir/OTP, localhost:9089)
  |- Agent loop (GenServer)
  |- 18 LLM providers, 3 compute tiers
  |- Multi-agent orchestration + swarms
  |- Memory, Vault, Knowledge graph
  |- Scheduler (cron + heartbeat)
  |- SSE streaming per session
```

The frontend is a compiled static SPA embedded in the Tauri shell. It communicates with the OSA backend exclusively over localhost — no external network calls from the shell layer.

---

## Pages

| Page | Route | Description |
|------|-------|-------------|
| Dashboard | `/app` | System health, KPIs, active agents, recent activity |
| Chat | `/app/chat` | Streaming chat with model selector, collapsible session history, thinking blocks |
| Agents | `/app/agents` | Live agent dashboard, org chart, multi-agent orchestration |
| Models | `/app/models` | Model browser, provider grouping, one-click model switch |
| Skills | `/app/skills` | Skill marketplace, enable/disable, bulk operations |
| Projects | `/app/projects` | Project tracking, goal trees, task linking |
| Tasks | `/app/tasks` | Scheduled tasks, cron presets, run history |
| Terminal | `/app/terminal` | Embedded terminal (xterm.js) |
| Signals | `/app/signals` | Signal classification feed, stats, patterns |
| Activity | `/app/activity` | Real-time event feed with verbosity controls |
| Usage | `/app/usage` | Token usage, cost tracking, budget management |
| Memory | `/app/memory` | Browse and manage structured Vault memory |
| Approvals | `/app/approvals` | Governance approval queue |
| Connectors | `/app/connectors` | Configure channel integrations |
| Settings | `/app/settings` | General, Provider, Voice, Permissions, Advanced, About |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Command palette |
| Cmd+1 | Dashboard |
| Cmd+2 | Chat |
| Cmd+3 | Agents |
| Cmd+4 | Models |
| Cmd+5 | Terminal |
| Cmd+6 | Settings |
| Cmd+7 | Connectors |
| Cmd+8 | Activity |
| Cmd+9 | Usage |
| Cmd+0 | Tasks |
| Cmd+Y | Toggle YOLO mode |
| Cmd+\ | Toggle sidebar |
| Cmd+, | Settings |
| Enter | Send message |
| Shift+Enter | New line |

---

## Project Structure

```
desktop/
├── src/
│   ├── routes/
│   │   ├── app/
│   │   │   ├── +layout.svelte      # App shell + overlays
│   │   │   ├── +page.svelte        # Dashboard (default)
│   │   │   ├── chat/               # Chat with session history
│   │   │   ├── agents/             # Agent dashboard + org chart
│   │   │   ├── models/             # Model browser
│   │   │   ├── skills/             # Skills marketplace
│   │   │   ├── projects/           # Project & goal tracking
│   │   │   ├── tasks/              # Scheduled tasks + runs
│   │   │   ├── terminal/           # Embedded terminal
│   │   │   ├── signals/            # Signal classification feed
│   │   │   ├── activity/           # Activity logs
│   │   │   ├── usage/              # Usage, costs, budgets
│   │   │   ├── memory/             # Memory Vault browser
│   │   │   ├── approvals/          # Governance approvals
│   │   │   ├── connectors/         # Channel integrations
│   │   │   └── settings/           # Settings (6 tabs)
│   │   └── onboarding/             # Setup wizard
│   ├── lib/
│   │   ├── api/                    # HTTP client, SSE, types
│   │   ├── components/             # 30+ Svelte components
│   │   ├── stores/                 # 20+ Svelte 5 stores
│   │   └── utils/                  # Platform detection
│   └── app.css                     # Glass theme tokens
├── src-tauri/
│   ├── src/
│   │   ├── lib.rs                  # App builder + plugins
│   │   ├── sidecar.rs              # Backend lifecycle
│   │   ├── commands.rs             # IPC (hardware, health, terminal)
│   │   └── tray.rs                 # System tray
│   └── tauri.conf.json
├── Makefile
└── package.json
```

---

## License

Proprietary. Copyright 2026 MIOSA Inc.
