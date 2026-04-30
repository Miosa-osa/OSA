defmodule OptimalSystemAgent.CommandCenter do
  @moduledoc """
  Command Center — aggregated dashboard and operational API.

  Provides summary views of agents, tiers, patterns, and metrics.
  The pattern list is sourced from `Agent.Orchestrator.Patterns` so callers
  receive plain maps (not raw tuples) that are safe to JSON-encode.
  """

  alias OptimalSystemAgent.Agent.Roster

  @doc "Top-level dashboard summary."
  @spec dashboard_summary() :: map()
  def dashboard_summary do
    agents = Roster.all() |> Map.values()
    total = length(agents)

    %{
      total_agents: total,
      running: 0,
      idle: total,
      tiers: tier_counts(agents),
      patterns: pattern_list()
    }
  end

  @doc "All available agent detail maps. Returns `{:ok, detail}` or `{:error, :not_found}`."
  @spec agent_detail(String.t()) :: {:ok, map()} | {:error, :not_found}
  def agent_detail(name) do
    case Roster.all() |> Map.get(name) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc "Tier breakdown — agent count per tier."
  @spec tier_breakdown() :: map()
  def tier_breakdown do
    Roster.all()
    |> Map.values()
    |> Enum.group_by(fn a -> Map.get(a, :tier, "unknown") end)
    |> Enum.map(fn {tier, members} -> {tier, length(members)} end)
    |> Map.new()
  end

  @doc "Metrics summary stub."
  @spec metrics_summary() :: map()
  def metrics_summary do
    %{
      total_sessions: 0,
      active_sessions: 0,
      total_tool_calls: 0,
      avg_response_ms: 0
    }
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp tier_counts(agents) do
    agents
    |> Enum.group_by(fn a -> Map.get(a, :tier, "unknown") end)
    |> Enum.map(fn {tier, members} -> %{tier: tier, count: length(members)} end)
  end

  defp pattern_list do
    OptimalSystemAgent.Agent.Orchestrator.Patterns.list_patterns()
    |> Enum.map(fn {name, desc} -> %{name: name, description: desc} end)
  end
end

defmodule OptimalSystemAgent.Agent.Roster do
  @moduledoc """
  Agent roster — loads agent definitions and exposes them as a flat map keyed by name.

  Uses `Agents.Registry` as the source of truth. Falls back to a built-in
  minimal roster when no agents are loaded from disk.
  """

  @doc "Return all agent definitions as `%{name => %{name:, tier:, description:, ...}}`."
  @spec all() :: %{String.t() => map()}
  def all do
    case OptimalSystemAgent.Agents.Registry.list() do
      [] ->
        built_in_roster()

      agents ->
        agents
        |> Enum.map(fn a -> {Map.get(a, :name, "unknown"), a} end)
        |> Map.new()
    end
  end

  # Minimal built-in roster so the command center always has at least one agent.
  defp built_in_roster do
    %{
      "master" => %{
        name: "master",
        tier: "orchestration",
        description: "Master orchestrator — routes tasks to specialized agents",
        prompt: "[REDACTED]"
      },
      "backend-elixir" => %{
        name: "backend-elixir",
        tier: "specialist",
        description: "Elixir/OTP backend specialist",
        prompt: "[REDACTED]"
      }
    }
  end
end

defmodule OptimalSystemAgent.Agent.Orchestrator.Patterns do
  @moduledoc """
  Swarm execution patterns available for multi-agent orchestration.

  Each pattern is a `{name, description}` tuple. This format is the
  authoritative representation — callers that need JSON-safe maps must
  convert via `Enum.map(fn {n, d} -> %{name: n, description: d} end)`.
  """

  @patterns [
    {"parallel", "Fan-out to multiple agents simultaneously for independent sub-tasks"},
    {"pipeline", "Sequential agent chain where each output feeds the next"},
    {"debate", "Two-agent adversarial debate with synthesis by a third agent"},
    {"review", "Primary agent drafts; reviewer agent critiques; primary refines"},
    {"pact", "Agents negotiate a shared plan before executing in parallel"}
  ]

  @doc "List all known swarm execution patterns as `{name, description}` tuples."
  @spec list_patterns() :: [{String.t(), String.t()}]
  def list_patterns, do: @patterns
end

defmodule OptimalSystemAgent.Sandbox.Provisioner do
  @moduledoc """
  Sandbox provisioner — allocates sandbox environments for agent code execution.

  This is a stub implementation. A real provisioner would communicate with
  the compute engine to create isolated execution environments.
  """
  require Logger

  @type template :: :default | :node | :python | :elixir | :go | :rust

  @doc "Provision a sandbox for the given OS ID."
  @spec provision(String.t(), template()) :: {:ok, String.t()} | {:error, term()}
  def provision(os_id, template \\ :default) do
    Logger.info("[Provisioner] Provisioning sandbox for os_id=#{os_id} template=#{template}")
    sprite_id = "sprite-#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, sprite_id}
  end

  @doc "Deprovision a sandbox by sprite ID."
  @spec deprovision(String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def deprovision(_sprite_id) do
    # Stub: always succeeds — no real provisioner state to clean up.
    :ok
  end
end

defmodule OptimalSystemAgent.Agent.HealthTracker do
  @moduledoc """
  Agent health tracker — collects liveness and performance data per agent.

  Uses an ETS table so reads are lock-free. The GenServer owns the table
  and updates it on heartbeat events.
  """
  use GenServer
  require Logger

  @table :osa_agent_health

  # ── Public API ─────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Return health data for all tracked agents."
  @spec all() :: [map()]
  def all do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_name, data} -> data end)
  end

  @doc "Return health data for a single agent by name."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [{^name, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @doc "Record a heartbeat for an agent."
  @spec heartbeat(String.t(), map()) :: :ok
  def heartbeat(name, extra \\ %{}) do
    ensure_table()
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = Map.merge(%{name: name, status: "healthy", last_seen: now}, extra)
    :ets.insert(@table, {name, entry})
    :ok
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  rescue
    ArgumentError ->
      # Table already exists (e.g. from a previous test run in the same node).
      {:ok, %{}}
  end

  # ── Private ────────────────────────────────────────────────────────

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> :ok
  end
end
