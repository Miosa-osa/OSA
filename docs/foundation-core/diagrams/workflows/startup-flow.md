# Startup Flow

## Overview

This diagram shows the complete startup sequence from `Application.start/2`
to the first request being accepted. Steps are ordered as they occur in time.
Steps marked `[async]` do not block the main startup path.

---

## Startup Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant OS as OS / Mix Release
    participant App as Application.start/2
    participant ETS as ETS Tables
    participant Soul as Soul + PromptLoader
    participant Infra as Supervisors.Infrastructure
    participant Sessions as Supervisors.Sessions
    participant AgentSvc as Supervisors.AgentServices
    participant Ext as Supervisors.Extensions
    participant PlatDB as Platform.Repo (opt-in)
    participant Channels as Channels.Starter
    participant HTTP as Bandit HTTP
    participant Ollama as Ollama Auto-Detect
    participant MCP as MCP.Client [async]

    OS->>App: Application.start(:normal, [])

    rect rgb(240, 248, 255)
        note over App,ETS: Phase 1 — Pre-supervision ETS initialization
        App->>ETS: :ets.new(:osa_cancel_flags, [:named_table, :public, :set])
        App->>ETS: :ets.new(:osa_files_read, [:named_table, :public, :set])
        App->>ETS: :ets.new(:osa_survey_answers, [:set, :public, :named_table])
        App->>ETS: :ets.new(:osa_context_cache, [:set, :public, :named_table])
        App->>ETS: :ets.new(:osa_survey_responses, [:bag, :public, :named_table])
        App->>ETS: :ets.new(:osa_session_provider_overrides, [:named_table, :public, :set])
        App->>ETS: :ets.new(:osa_pending_questions, [:named_table, :public, :set])
    end

    rect rgb(240, 255, 240)
        note over App,Soul: Phase 2 — Personality + prompts (persistent_term)
        App->>Soul: Soul.load()
        Soul-->>App: soul content loaded into persistent_term
        App->>Soul: PromptLoader.load()
        Soul-->>App: prompt templates loaded into persistent_term
    end

    rect rgb(255, 248, 240)
        note over App,PlatDB: Phase 3 — Optional Platform DB
        App->>PlatDB: platform_repo_children() — check DATABASE_URL
        alt DATABASE_URL is set
            PlatDB-->>App: [Platform.Repo] added to children
        else DATABASE_URL not set
            PlatDB-->>App: [] (no platform repo)
        end
    end

    rect rgb(248, 240, 255)
        note over App,Infra: Phase 4 — Supervision tree startup (rest_for_one)
        App->>Infra: Supervisor.start_link(children, strategy: :rest_for_one)

        Infra->>Infra: start SessionRegistry [Registry]
        Infra->>Infra: start Events.TaskSupervisor [Task.Supervisor]
        Infra->>Infra: start Phoenix.PubSub [GenServer]
        Infra->>Infra: start Events.Bus [GenServer] — glc:compile(:osa_event_router)
        Infra->>Infra: start Events.DLQ [GenServer]
        Infra->>Infra: start Bridge.PubSub [GenServer]
        Infra->>Infra: start Store.Repo [Ecto.Repo] — SQLite WAL open
        Infra->>Infra: start EventStream [GenServer]
        Infra->>Infra: start Telemetry.Metrics [GenServer]
        Infra->>Infra: start MiosaLLM.HealthChecker [GenServer]
        Infra->>Infra: start MiosaProviders.Registry [GenServer] — glc:compile(:osa_provider_router)
        Infra->>Infra: start Tools.Registry [GenServer] — glc:compile(:osa_tool_dispatcher)
        Infra->>Infra: start Tools.Cache [GenServer]
        Infra->>Infra: start Machines [GenServer]
        Infra->>Infra: start Commands [GenServer]
        Infra->>Infra: start OS.Registry [GenServer]
        Infra->>Infra: start MCP.Registry [Registry]
        Infra->>Infra: start MCP.Supervisor [DynamicSupervisor]
        Infra-->>App: {:ok, pid}

        App->>Sessions: start Supervisors.Sessions (one_for_one)
        Sessions->>Sessions: start Channels.Supervisor [DynamicSupervisor]
        Sessions->>Sessions: start EventStreamRegistry [Registry]
        Sessions->>Sessions: start SessionSupervisor [DynamicSupervisor]
        Sessions-->>App: {:ok, pid}

        App->>AgentSvc: start Supervisors.AgentServices (one_for_one)
        AgentSvc->>AgentSvc: start Agent.Memory, HeartbeatState, Tasks
        AgentSvc->>AgentSvc: start MiosaBudget.Budget
        AgentSvc->>AgentSvc: start Agent.Orchestrator, Progress, Hooks
        AgentSvc->>AgentSvc: start Agent.Learning, MiosaKnowledge.Store
        AgentSvc->>AgentSvc: start Agent.Memory.KnowledgeBridge
        AgentSvc->>AgentSvc: start Vault.Supervisor
        AgentSvc->>AgentSvc: start Agent.Scheduler, Compactor, Cortex
        AgentSvc->>AgentSvc: start Webhooks.Dispatcher
        AgentSvc-->>App: {:ok, pid}

        App->>Ext: start Supervisors.Extensions (one_for_one)
        Ext->>Ext: start opt-in extensions (Treasury, Intelligence, Swarm,\nFleet, Sidecars, Sandbox, Wallet, Updater, AMQP)
        Ext-->>App: {:ok, pid}

        App->>Channels: start Channels.Starter [GenServer]
        Note over Channels: handle_continue starts configured\nchannel adapters (CLI, Telegram, etc.)

        App->>HTTP: start Bandit plug: Channels.HTTP, port: 9089
        HTTP-->>App: {:ok, pid} — HTTP now accepting connections
    end

    rect rgb(255, 255, 240)
        note over App,MCP: Phase 5 — Post-start auto-detection and MCP (non-blocking)
        App->>Ollama: MiosaProviders.Ollama.auto_detect_model() [synchronous]
        Ollama-->>App: best local model stored in persistent_term
        App->>Ollama: Agent.Tier.detect_ollama_tiers() [synchronous]
        Ollama-->>App: tier assignments stored

        App->>MCP: Task.start — MCP.Client.start_servers() [async]
        MCP->>MCP: launch configured MCP server OS processes
        MCP->>MCP: JSON-RPC initialize handshake per server
        MCP->>MCP: MCP.Client.list_tools() — await all handshakes
        MCP->>MCP: Tools.Registry.register_mcp_tools()
        MCP-->>App: [async complete — tools now available]
    end

    App-->>OS: {:ok, supervisor_pid}
    Note over OS,HTTP: System fully started\nHTTP API accepting requests\nAgent sessions can be created
```

---

## Startup Time Budget

| Phase | Typical duration | Notes |
|---|---|---|
| ETS initialization | < 1 ms | 7 table creations |
| Soul + PromptLoader | 10–50 ms | Disk reads, persistent_term writes |
| Platform.Repo (if enabled) | 50–200 ms | PostgreSQL connect + schema check |
| Infrastructure supervisor | 20–100 ms | goldrush compile = 5–20 ms per router |
| Sessions + AgentServices + Extensions | 10–50 ms | GenServer init callbacks |
| Channels.Starter | 5–20 ms | Channel adapter handshakes |
| Bandit HTTP | < 5 ms | Socket bind + listen |
| Ollama auto-detect (synchronous) | 50–500 ms | HTTP call to local Ollama |
| MCP server startup (async) | 1–10 s | Depends on server count and latency |

Total blocking startup (before HTTP accepts): typically 100–500 ms on a
local machine without PostgreSQL. MCP startup is async and does not
contribute to the blocking time.

---

## Startup Failure Modes

| Component | Failure | Behavior |
|---|---|---|
| ETS table creation | Name collision | `ArgumentError` raised — BEAM halts |
| Soul.load() | File not found | Warning logged; default identity used |
| Infrastructure supervisor | Child init failure | Supervisor crashes; BEAM halts (permanent process) |
| Store.Repo | SQLite file locked | Repo crashes; Infrastructure crashes; BEAM halts |
| Bandit HTTP | Port 9089 in use | `{:error, :eaddrinuse}` — BEAM halts |
| Ollama auto-detect | Ollama not running | Warning logged; Ollama marked unavailable |
| MCP server startup | Server binary missing | Warning logged; server skipped |
