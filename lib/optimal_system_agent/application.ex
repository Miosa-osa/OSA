defmodule OptimalSystemAgent.Application do
  @moduledoc """
  OTP Application supervisor for the Optimal System Agent.

  Supervision tree:
    - SessionRegistry (process registry for agent sessions)
    - PubSub (internal event fan-out — standalone, no Phoenix framework)
    - Events.Bus (goldrush-compiled :osa_event_router)
    - Bridge.PubSub (goldrush → PubSub bridge, 3 tiers)
    - Repo (SQLite3 persistent storage)
    - Providers.Registry (LLM provider routing via :osa_provider_router)
    - Skills.Registry (tool dispatch via :osa_tool_dispatcher)
    - Machines (composable skill set activation from ~/.osa/config.json)
    - OS.Registry (OS template discovery, connection, context injection)
    - MCP.Supervisor (MCP server/client processes)
    - Channels.Supervisor (platform adapters: CLI, HTTP, Telegram, Discord, Slack,
        WhatsApp, Signal, Matrix, Email, QQ, DingTalk, Feishu)
    - Channels.Manager (starts configured adapters after boot)
    - Agent.Memory (persistent JSONL session storage)
    - Agent.Workflow (multi-step task tracking + LLM decomposition)
    - Agent.Orchestrator (autonomous task orchestration, multi-agent spawning)
    - Agent.Progress (real-time progress tracking for orchestrated tasks)
    - Agent.Loop (stateful ReAct agent via :osa_agent_loop)
    - Agent.Scheduler (cron + heartbeat)
    - Agent.Compactor (context compression, 3 thresholds)
    - Agent.Cortex (memory synthesis, periodic knowledge bulletin)
    - Intelligence.Supervisor (Signal Theory unique modules)
    - Swarm.Supervisor (multi-agent swarm coordination subsystem)
    - Sandbox.Supervisor (Docker container isolation — started when sandbox_enabled: true)
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Process registry for agent sessions
        {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry},

        # Core infrastructure
        {Phoenix.PubSub, name: OptimalSystemAgent.PubSub},
        OptimalSystemAgent.Events.Bus,
        OptimalSystemAgent.Bridge.PubSub,
        OptimalSystemAgent.Store.Repo,

        # LLM providers (goldrush-compiled :osa_provider_router)
        OptimalSystemAgent.Providers.Registry,

        # Skills + machines (goldrush-compiled :osa_tool_dispatcher)
        OptimalSystemAgent.Skills.Registry,
        OptimalSystemAgent.Machines,

        # Slash command registry (built-in + custom + agent-created)
        OptimalSystemAgent.Commands,

        # OS template discovery and connection
        OptimalSystemAgent.OS.Registry,

        # MCP integration
        {DynamicSupervisor, name: OptimalSystemAgent.MCP.Supervisor, strategy: :one_for_one},

        # Channel adapters
        {DynamicSupervisor, name: OptimalSystemAgent.Channels.Supervisor, strategy: :one_for_one},

        # Agent processes
        OptimalSystemAgent.Agent.Memory,
        OptimalSystemAgent.Agent.HeartbeatState,
        OptimalSystemAgent.Agent.Workflow,
        OptimalSystemAgent.Agent.Budget,
        OptimalSystemAgent.Agent.TaskQueue,
        OptimalSystemAgent.Agent.Orchestrator,
        OptimalSystemAgent.Agent.Progress,
        OptimalSystemAgent.Agent.Hooks,
        OptimalSystemAgent.Agent.Learning,
        OptimalSystemAgent.Agent.Scheduler,
        OptimalSystemAgent.Agent.Compactor,
        OptimalSystemAgent.Agent.Cortex,
        OptimalSystemAgent.Agent.Treasury,

        # Communication intelligence (Signal Theory unique)
        OptimalSystemAgent.Intelligence.Supervisor,

        # Multi-agent swarm collaboration system
        OptimalSystemAgent.Swarm.Supervisor,

        # HTTP channel — Plug/Bandit on port 8089 (SDK API surface)
        # Started LAST so all agent processes are ready before accepting requests
        {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()}
      ] ++
        fleet_children() ++
        sidecar_children() ++ sandbox_children() ++ wallet_children() ++ updater_children()

    opts = [strategy: :one_for_one, name: OptimalSystemAgent.Supervisor]

    # Load soul/personality files into persistent_term BEFORE supervision tree
    # starts — agents need identity/soul content from their first LLM call.
    OptimalSystemAgent.Soul.load()
    OptimalSystemAgent.PromptLoader.load()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Auto-detect best Ollama model and tier assignments (fast, ~100ms)
        if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
          OptimalSystemAgent.Providers.Ollama.auto_detect_model()
        end

        # Always detect Ollama tiers if Ollama is reachable (for fallback routing)
        Task.start(fn -> OptimalSystemAgent.Agent.Tier.detect_ollama_tiers() end)

        # Start configured channel adapters after the supervision tree is up.
        Task.start(fn ->
          Process.sleep(250)
          OptimalSystemAgent.Channels.Manager.start_configured_channels()
        end)

        {:ok, pid}

      error ->
        error
    end
  end

  # Unified sidecar startup: Manager first (creates registry + circuit breaker tables),
  # then individual sidecars based on config flags.
  defp sidecar_children do
    manager = [OptimalSystemAgent.Sidecar.Manager]

    go =
      if Application.get_env(:optimal_system_agent, :go_tokenizer_enabled, false) do
        Logger.info("[Application] Go tokenizer enabled — starting Go.Tokenizer")
        [OptimalSystemAgent.Go.Tokenizer]
      else
        []
      end

    python =
      if Application.get_env(:optimal_system_agent, :python_sidecar_enabled, false) do
        Logger.info("[Application] Python sidecar enabled — starting Python.Supervisor")
        [OptimalSystemAgent.Python.Supervisor]
      else
        []
      end

    go_git =
      if Application.get_env(:optimal_system_agent, :go_git_enabled, false) do
        Logger.info("[Application] Go git sidecar enabled — starting Go.Git")
        [OptimalSystemAgent.Go.Git]
      else
        []
      end

    go_sysmon =
      if Application.get_env(:optimal_system_agent, :go_sysmon_enabled, false) do
        Logger.info("[Application] Go sysmon sidecar enabled — starting Go.Sysmon")
        [OptimalSystemAgent.Go.Sysmon]
      else
        []
      end

    whatsapp_web =
      if Application.get_env(:optimal_system_agent, :whatsapp_web_enabled, false) do
        Logger.info("[Application] WhatsApp Web sidecar enabled — starting WhatsAppWeb")
        [OptimalSystemAgent.WhatsAppWeb]
      else
        []
      end

    manager ++ go ++ python ++ go_git ++ go_sysmon ++ whatsapp_web
  end

  # Fleet management (registry + sentinels) — opt-in via OSA_FLEET_ENABLED=true
  defp fleet_children do
    if Application.get_env(:optimal_system_agent, :fleet_enabled, false) do
      Logger.info("[Application] Fleet enabled — starting Fleet.Supervisor")
      [OptimalSystemAgent.Fleet.Supervisor]
    else
      []
    end
  end

  # Only add Sandbox.Supervisor to the tree when the sandbox is enabled.
  # This keeps the default startup path completely unchanged.
  defp sandbox_children do
    if Application.get_env(:optimal_system_agent, :sandbox_enabled, false) do
      Logger.info("[Application] Sandbox enabled — starting Sandbox.Supervisor")
      [OptimalSystemAgent.Sandbox.Supervisor]
    else
      []
    end
  end

  # Wallet integration — opt-in via OSA_WALLET_ENABLED=true
  defp wallet_children do
    if Application.get_env(:optimal_system_agent, :wallet_enabled, false) do
      Logger.info("[Application] Wallet enabled — starting Wallet + Mock provider")

      [
        OptimalSystemAgent.Integrations.Wallet.Mock,
        OptimalSystemAgent.Integrations.Wallet
      ]
    else
      []
    end
  end

  # OTA updater — opt-in via OSA_UPDATE_ENABLED=true
  defp updater_children do
    if Application.get_env(:optimal_system_agent, :update_enabled, false) do
      Logger.info("[Application] OTA updater enabled — starting System.Updater")
      [OptimalSystemAgent.System.Updater]
    else
      []
    end
  end

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 8089)
      port -> String.to_integer(port)
    end
  end
end
