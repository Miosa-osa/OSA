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
    children = [
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
      OptimalSystemAgent.Agent.Workflow,
      OptimalSystemAgent.Agent.Orchestrator,
      OptimalSystemAgent.Agent.Progress,
      OptimalSystemAgent.Agent.Scheduler,
      OptimalSystemAgent.Agent.Compactor,
      OptimalSystemAgent.Agent.Cortex,

      # Communication intelligence (Signal Theory unique)
      OptimalSystemAgent.Intelligence.Supervisor,

      # Multi-agent swarm collaboration system
      OptimalSystemAgent.Swarm.Supervisor,

      # HTTP channel — Plug/Bandit on port 8089 (SDK API surface)
      # Started LAST so all agent processes are ready before accepting requests
      {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()},
    ] ++ sandbox_children()

    opts = [strategy: :one_for_one, name: OptimalSystemAgent.Supervisor]

    # Load soul/personality files into persistent_term BEFORE supervision tree
    # starts — agents need identity/soul content from their first LLM call.
    OptimalSystemAgent.Soul.load()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Start configured channel adapters after the supervision tree is up.
        # Each adapter's init/1 returns :ignore when its config is absent,
        # so this is safe to call unconditionally on every boot.
        Task.start(fn ->
          # Brief delay to allow Bandit to finish port binding
          Process.sleep(250)
          OptimalSystemAgent.Channels.Manager.start_configured_channels()
        end)

        {:ok, pid}

      error ->
        error
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

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 8089)
      port -> String.to_integer(port)
    end
  end
end
