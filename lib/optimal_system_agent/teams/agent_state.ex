defmodule OptimalSystemAgent.Teams.AgentState do
  @moduledoc """
  Agent state record within a team.

  Tracks identity, role, runtime status, and cost accounting for an agent
  that belongs to a team. Stored per-agent in the team's ETS agents table
  (keyed by agent_id).

  ## Status lifecycle

      idle -> working -> idle
      idle -> suspended -> idle
      working -> healing -> idle

  The `task_id` field is non-nil only when status is `:working`.
  """

  alias OptimalSystemAgent.Teams.TableRegistry

  @enforce_keys [:agent_id, :name, :role, :model, :spawned_at]
  defstruct [
    :agent_id,
    :name,
    :role,
    :model,
    :task_id,
    :spawned_at,
    status: :idle,
    token_usage: 0,
    cost_usd: 0.0,
    escalation_count: 0
  ]

  @type status :: :idle | :working | :suspended | :healing

  @type t :: %__MODULE__{
          agent_id: String.t(),
          name: String.t(),
          role: String.t(),
          model: String.t() | atom(),
          status: status(),
          task_id: String.t() | nil,
          token_usage: non_neg_integer(),
          cost_usd: float(),
          escalation_count: non_neg_integer(),
          spawned_at: DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc "Build a new AgentState struct with sensible defaults."
  @spec new(String.t(), String.t(), String.t(), String.t() | atom()) :: t()
  def new(agent_id, name, role, model) do
    %__MODULE__{
      agent_id: agent_id,
      name: name,
      role: role,
      model: model,
      spawned_at: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Persistence — ETS helpers
  # ---------------------------------------------------------------------------

  @doc "Write an AgentState into the team's agents ETS table."
  @spec put(String.t(), t()) :: :ok
  def put(team_id, %__MODULE__{agent_id: agent_id} = state) do
    :ets.insert(TableRegistry.agents_table(team_id), {agent_id, state})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Fetch an AgentState from the team's agents ETS table."
  @spec get(String.t(), String.t()) :: t() | nil
  def get(team_id, agent_id) do
    case :ets.lookup(TableRegistry.agents_table(team_id), agent_id) do
      [{^agent_id, state}] -> state
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Delete an AgentState from the team's agents ETS table."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(team_id, agent_id) do
    :ets.delete(TableRegistry.agents_table(team_id), agent_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc "List all AgentState records for the given team."
  @spec list(String.t()) :: [t()]
  def list(team_id) do
    TableRegistry.agents_table(team_id)
    |> :ets.tab2list()
    |> Enum.map(fn {_id, state} -> state end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Update the status of an agent in the team's ETS table.

  Returns `{:ok, updated_state}` or `{:error, :not_found}`.
  """
  @spec update_status(String.t(), String.t(), status()) ::
          {:ok, t()} | {:error, :not_found}
  def update_status(team_id, agent_id, new_status) do
    case get(team_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        updated = %{state | status: new_status}
        put(team_id, updated)
        {:ok, updated}
    end
  end

  @doc """
  Assign the agent to a task and transition to :working.

  Returns `{:ok, updated_state}` or `{:error, :not_found}`.
  """
  @spec assign_task(String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found}
  def assign_task(team_id, agent_id, task_id) do
    case get(team_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        updated = %{state | status: :working, task_id: task_id}
        put(team_id, updated)
        {:ok, updated}
    end
  end

  @doc """
  Record token usage and cost for an agent.

  Accumulates onto existing totals. Returns `{:ok, updated_state}` or
  `{:error, :not_found}`.
  """
  @spec record_cost(String.t(), String.t(), non_neg_integer(), float()) ::
          {:ok, t()} | {:error, :not_found}
  def record_cost(team_id, agent_id, tokens, cost_usd) do
    case get(team_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        updated = %{state |
          token_usage: state.token_usage + tokens,
          cost_usd: state.cost_usd + cost_usd
        }
        put(team_id, updated)
        {:ok, updated}
    end
  end

  @doc "Increment the escalation counter (model tier up-shift) for an agent."
  @spec increment_escalation(String.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found}
  def increment_escalation(team_id, agent_id) do
    case get(team_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        updated = %{state | escalation_count: state.escalation_count + 1}
        put(team_id, updated)
        {:ok, updated}
    end
  end
end
