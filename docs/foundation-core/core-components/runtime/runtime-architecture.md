# Runtime Architecture

## Overview

OSA is an OTP application built on Elixir/BEAM. The entry point is
`OptimalSystemAgent.Application`, declared in `mix.exs` as:

```elixir
def application do
  [
    extra_applications: [:logger, :crypto],
    mod: {OptimalSystemAgent.Application, []}
  ]
end
```

The release is named `osagent`:

```elixir
defp releases do
  [
    osagent: [
      include_executables_for: [:unix],
      applications: [runtime_tools: :permanent],
      steps: [:assemble, &copy_go_tokenizer/1, &copy_osagent_wrapper/1]
    ]
  ]
end
```

## Entry Points

Three ways to start OSA:

| Entry point | Command | Description |
|-------------|---------|-------------|
| Shell wrapper | `bin/osagent` | OTP release binary dispatching subcommands via `eval` |
| Mix alias | `mix chat` | Runs `OptimalSystemAgent.Channels.CLI.start()` inline |
| HTTP mode | `bin/osagent serve` | Headless API server; starts the BEAM, no interactive prompt |

The shell wrapper dispatches to OTP release subcommands:

```sh
case "${1:-chat}" in
  version) exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.version()" ;;
  setup)   exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.setup()" ;;
  serve)   exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.serve()" ;;
  doctor)  exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.doctor()" ;;
  chat|*)  exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.chat()" ;;
esac
```

## Application.start/2

`Application.start/2` runs in a strict sequence before the supervision tree:

### 1. ETS Table Initialization

Seven named ETS tables are created unconditionally. They must exist before any
supervised child starts because children read and write them during their own
`init/1`.

| Table | Options | Purpose |
|-------|---------|---------|
| `osa_cancel_flags` | `public, set` | Per-session loop cancel flags; written by `Loop.cancel/1`, polled each ReAct iteration |
| `osa_files_read` | `public, set` | Tracks which files have been read per session; used by the `pre_tool_use` hook to warn on unread writes |
| `osa_survey_answers` | `public, set` | HTTP endpoint writes answers here; `Loop.ask_user_question/4` polls and consumes them |
| `osa_context_cache` | `public, set` | Caches Ollama model context window sizes from `/api/show`; avoids repeated HTTP calls |
| `osa_survey_responses` | `public, bag` | Survey/waitlist responses when platform DB is disabled |
| `osa_session_provider_overrides` | `public, set` | Per-session provider/model overrides set via hot-swap API; rows: `{session_id, provider, model}` |
| `osa_pending_questions` | `public, set` | Tracks in-flight `ask_user` questions; allows `GET /sessions/:id/pending_questions` to show agent-blocked state |

### 2. Supervision Tree

Children start in order under `:rest_for_one`. A crash in an earlier child
tears down all children started after it.

```
OptimalSystemAgent.Supervisor  (rest_for_one)
├── Platform.Repo              (optional — only when DATABASE_URL is set)
├── Task.Supervisor            (fire-and-forget async work)
├── Supervisors.Infrastructure (core infrastructure — rest_for_one)
├── Supervisors.Sessions       (channel adapters, event streams, session loop — one_for_one)
├── Supervisors.AgentServices  (memory, hooks, learning, scheduler — one_for_one)
├── Supervisors.Extensions     (opt-in subsystems — one_for_one)
├── Channels.Starter           (deferred channel startup in handle_continue)
└── Bandit                     (HTTP on OSA_HTTP_PORT, default 9089)
```

### 3. Soul and Prompt Loading

Before `Supervisor.start_link/2` is called, two loaders populate
`persistent_term` entries that every agent session reads on its first LLM call:

```elixir
OptimalSystemAgent.Soul.load()
OptimalSystemAgent.PromptLoader.load()
```

`Soul.load/0` reads `~/.osa/SOUL.md`, `~/.osa/IDENTITY.md`, and
`~/.osa/USER.md`. `PromptLoader.load/0` reads YAML skill files from
`~/.osa/skills/`. Both write into `:persistent_term` so reads are zero-copy
after startup.

### 4. Post-Start Initialization

After the supervisor returns `{:ok, pid}`, two synchronous calls run in the
caller process:

```elixir
MiosaProviders.Ollama.auto_detect_model()
OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
```

These are synchronous so that the CLI banner shows the correct model name. Then
MCP server startup runs in a `Task` to avoid blocking the boot:

```elixir
Task.start(fn ->
  OptimalSystemAgent.MCP.Client.start_servers()
  OptimalSystemAgent.MCP.Client.list_tools()
  OptimalSystemAgent.Tools.Registry.register_mcp_tools()
end)
```

## Subsystem Supervisors

### Infrastructure (rest_for_one)

Core processes that all other subsystems depend on. The `:rest_for_one` strategy
enforces strict startup ordering.

```
Infrastructure
├── SessionRegistry          (Registry, unique — session name lookup)
├── Events.TaskSupervisor    (Task.Supervisor, max 100 — event dispatch tasks)
├── PubSub                   (Phoenix.PubSub — internal fan-out)
├── Events.Bus               (goldrush-compiled :osa_event_router)
├── Events.DLQ               (dead-letter queue with exponential backoff)
├── Bridge.PubSub            (bridge between Events.Bus and Phoenix.PubSub)
├── Store.Repo               (SQLite3 via Ecto — persistent agent storage)
├── EventStream              (SSE stream for Command Center)
├── Telemetry.Metrics        (subscribes to Events.Bus)
├── MiosaLLM.HealthChecker   (circuit breaker for provider availability)
├── MiosaProviders.Registry  (goldrush-compiled :osa_provider_router)
├── Tools.Registry           (goldrush-compiled :osa_tool_dispatcher)
├── Tools.Cache              (tool result caching)
├── Machines                 (OS template registry)
├── Commands                 (slash command registry)
├── OS.Registry              (OS template discovery)
├── MCP.Registry             (Registry for MCP server name lookup)
└── MCP.Supervisor           (DynamicSupervisor for per-server GenServers)
```

### Sessions (one_for_one)

```
Sessions
├── Channels.Supervisor      (DynamicSupervisor — CLI, HTTP, Telegram, Discord, Slack)
├── EventStreamRegistry      (Registry — per-session stream lookup)
└── SessionSupervisor        (DynamicSupervisor — one Loop GenServer per session)
```

### AgentServices (one_for_one)

Memory, hooks, learning engine, scheduler, and orchestration services. Each is
independent — a scheduler crash does not restart the memory subsystem.

### Extensions (one_for_one)

All opt-in subsystems. Each child group is conditionally included based on
environment variables read at boot:

| Subsystem | Guard |
|-----------|-------|
| Treasury | `OSA_TREASURY_ENABLED=true` |
| Intelligence | Always started (dormant until wired) |
| Swarm | Always started (Mailbox + SwarmMode + AgentPool) |
| Fleet | `OSA_FLEET_ENABLED=true` |
| Go Tokenizer | `OSA_GO_TOKENIZER=true` |
| Python Sidecar | `OSA_PYTHON_SIDECAR=true` |
| Go Git | `go_git_enabled: true` in config |
| Go Sysmon | `go_sysmon_enabled: true` in config |
| WhatsApp Web | `whatsapp_web_enabled: true` in config |
| Sandbox | `OSA_SANDBOX_ENABLED=true` |
| Wallet | `OSA_WALLET_ENABLED=true` |
| OTA Updater | `OSA_UPDATE_ENABLED=true` |
| AMQP | `AMQP_URL` present |

## HTTP Server

Bandit starts last so all agent processes are ready before the server accepts
connections:

```elixir
{Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()}
```

Port resolution order: `OSA_HTTP_PORT` env var → application config →
default `9089`.

## Release Build Steps

The `osagent` release executes two custom steps after `:assemble`:

1. `copy_go_tokenizer/1` — copies `priv/go/tokenizer/osa-tokenizer` into the
   release `priv` directory. Skipped silently if the binary is not present.
2. `copy_osagent_wrapper/1` — renames the generated `bin/osagent` release
   script to `bin/osagent_release` and writes the shell wrapper that dispatches
   subcommands.
