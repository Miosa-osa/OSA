defmodule OptimalSystemAgent.Application do
  @moduledoc """
  OTP Application supervisor for the Optimal System Agent.

  The supervision tree is organised into 4 logical subsystem supervisors
  plus the HTTP server and deferred channel startup:

    Infrastructure  — registries, pub/sub, event bus, storage, telemetry,
                      provider/tool routing, MCP integration
    Sessions        — channel adapters, event stream registry, session DynamicSupervisor
    AgentServices   — memory, workflow, orchestration, hooks, learning, scheduler, etc.
    Extensions      — opt-in subsystems: treasury, intelligence, swarm, fleet,
                      sidecars, sandbox, wallet, updater, AMQP

  The top-level strategy remains `:rest_for_one` so that a crash in
  Infrastructure (core) tears down everything above it, while each subsystem
  supervisor uses the strategy most appropriate for its children.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Application.put_env(:optimal_system_agent, :start_time, System.system_time(:second))

    # ETS table for Loop cancel flags — must exist before any agent session starts.
    # public + set so Loop.cancel/1 and run_loop can read/write concurrently.
    :ets.new(:osa_cancel_flags, [:named_table, :public, :set])

    # ETS table for read-before-write tracking — tracks which files have been read
    # per session so the pre_tool_use hook can nudge when writing unread files.
    :ets.new(:osa_files_read, [:named_table, :public, :set])

    # ETS table for ask_user_question survey answers — the HTTP endpoint writes
    # answers here, Loop.ask_user_question/4 polls and consumes them.
    :ets.new(:osa_survey_answers, [:set, :public, :named_table])

    # ETS table for caching Ollama model context window sizes — avoids repeated
    # /api/show HTTP calls since context_length doesn't change without re-pull.
    :ets.new(:osa_context_cache, [:set, :public, :named_table])

    # ETS table for survey/waitlist responses when platform DB is not enabled.
    # Rows: {unique_integer, body_map, datetime}
    :ets.new(:osa_survey_responses, [:bag, :public, :named_table])

    # ETS table for per-session provider/model overrides set via hot-swap API.
    # Rows: {session_id, provider, model}
    :ets.new(:osa_session_provider_overrides, [:named_table, :public, :set])

    # ETS table for tracking pending ask_user questions.
    # Lets GET /sessions/:id/pending_questions show when the agent is blocked.
    # Rows: {ref_string, %{session_id, question, options, asked_at}}
    :ets.new(:osa_pending_questions, [:named_table, :public, :set])

    # ETS table for subagent session counters (Orchestrator.next_subagent_number/1)
    :ets.new(:osa_subagent_counters, [:named_table, :public, :set])

    # Sandbox config (reads ~/.osa/sandbox.json if present)
    OptimalSystemAgent.Sandbox.Router.load_config()

    # Team coordination tables (shared task list, messaging, scratchpad)
    OptimalSystemAgent.Team.init_tables()

    # Context Mesh registry table
    OptimalSystemAgent.ContextMesh.Registry.init_table()

    # Peer protocol tables (handoffs, reviews, negotiations, discovery)
    OptimalSystemAgent.Peer.Protocol.init_table()
    OptimalSystemAgent.Peer.Review.init_table()
    OptimalSystemAgent.Peer.Negotiation.init_table()
    OptimalSystemAgent.Peer.Discovery.init_tables()

    # File locking intent broadcaster tables
    OptimalSystemAgent.FileLocking.IntentBroadcaster.init_tables()

    # Workspace session tracking table
    OptimalSystemAgent.Workspace.Session.init_table()

    # Workspace SQLite tables (workspaces + task_journals)
    OptimalSystemAgent.Workspace.Store.init()

    # Load agent definitions from priv/agents/ and ~/.osa/agents/
    OptimalSystemAgent.Agents.Registry.load()

    children =
      platform_repo_children() ++
      [
        # General-purpose Task.Supervisor for fire-and-forget async work
        # (HTTP message dispatch, background learning, etc.)
        {Task.Supervisor, name: OptimalSystemAgent.TaskSupervisor},

        OptimalSystemAgent.Supervisors.Infrastructure,
        OptimalSystemAgent.Supervisors.Sessions,
        OptimalSystemAgent.Supervisors.AgentServices,
        OptimalSystemAgent.Supervisors.Extensions,

        # Deferred channel startup — starts configured channels in handle_continue
        OptimalSystemAgent.Channels.Starter,

        # HTTP channel — Plug/Bandit on configured port (SDK API surface)
        # Started LAST so all agent processes are ready before accepting requests
        {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()}
      ]

    opts = [strategy: :rest_for_one, name: OptimalSystemAgent.Supervisor]

    # Load soul/personality files into persistent_term BEFORE supervision tree
    # starts — agents need identity/soul content from their first LLM call.
    OptimalSystemAgent.Soul.load()
    OptimalSystemAgent.PromptLoader.load()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Auto-detect best Ollama model + tier assignments SYNCHRONOUSLY at boot
        # so the banner shows the correct model (not a stale fallback)
        OptimalSystemAgent.Providers.Ollama.auto_detect_model()
        OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()

        {:ok, pid}

      error ->
        error
    end
  end

  defp platform_repo_children do
    []
  end

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 9089)
      port -> String.to_integer(port)
    end
  end
end
