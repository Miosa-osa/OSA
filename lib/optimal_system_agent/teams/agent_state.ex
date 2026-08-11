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

  # NOTE: these all address the ONE shared `:osa_team_agents` table with a
  # `{team_id, agent_id}` composite key. It used to be a per-team named table
  # whose name was minted from the team id — one permanently un-collectable atom
  # per team. See `TableRegistry`'s moduledoc.

  @doc "Write an AgentState into the shared agents ETS table."
  @spec put(String.t(), t()) :: :ok
  def put(team_id, %__MODULE__{agent_id: agent_id} = state) do
    TableRegistry.ensure_tables(team_id)
    :ets.insert(TableRegistry.agents_table(), {TableRegistry.agent_key(team_id, agent_id), state})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Fetch an AgentState from the shared agents ETS table."
  @spec get(String.t(), String.t()) :: t() | nil
  def get(team_id, agent_id) do
    key = TableRegistry.agent_key(team_id, agent_id)

    case :ets.lookup(TableRegistry.agents_table(), key) do
      [{^key, state}] -> state
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Delete an AgentState from the shared agents ETS table."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(team_id, agent_id) do
    :ets.delete(TableRegistry.agents_table(), TableRegistry.agent_key(team_id, agent_id))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  List all AgentState records for the given team.

  Selects on the key's team half rather than dumping the table, so one team's
  listing never sees another's rows now that storage is shared.
  """
  @spec list(String.t()) :: [t()]
  def list(team_id) do
    TableRegistry.agents_table()
    |> :ets.match({{team_id, :_}, :"$1"})
    |> Enum.map(fn [state] -> state end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------
  #
  # Every mutation below is an accumulate-or-transition on a row that more than
  # one process can hold at once (the team Manager, the nervous system's
  # rebalancer, and each agent's own reporting path). They used to be plain
  # get -> struct-update -> `:ets.insert/2` sequences with no serialisation and
  # no `update_counter`, so two concurrent `record_cost/4` calls both read the
  # same totals and the second insert silently discarded the first's tokens and
  # spend. Cost accounting that loses writes under concurrency is worse than no
  # accounting, because it reads as authoritative.
  #
  # `update/3` below closes that with a compare-and-swap: `:ets.select_replace/2`
  # only rewrites the row if it still holds exactly the struct we read, and
  # otherwise we re-read and retry. (A struct has a fixed key set, so ETS map
  # patterns — which match on the listed keys — are an exact match here.)

  @doc """
  Update the status of an agent in the team's ETS table.

  Returns `{:ok, updated_state}` or `{:error, :not_found}`.
  """
  @spec update_status(String.t(), String.t(), status()) ::
          {:ok, t()} | {:error, :not_found}
  def update_status(team_id, agent_id, new_status) do
    update(team_id, agent_id, &%{&1 | status: new_status})
  end

  @doc """
  Assign the agent to a task and transition to :working.

  Returns `{:ok, updated_state}` or `{:error, :not_found}`.
  """
  @spec assign_task(String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found}
  def assign_task(team_id, agent_id, task_id) do
    update(team_id, agent_id, &%{&1 | status: :working, task_id: task_id})
  end

  @doc """
  Record token usage and cost for an agent.

  Accumulates onto existing totals. Returns `{:ok, updated_state}` or
  `{:error, :not_found}`.
  """
  @spec record_cost(String.t(), String.t(), non_neg_integer(), float()) ::
          {:ok, t()} | {:error, :not_found}
  def record_cost(team_id, agent_id, tokens, cost_usd) do
    update(
      team_id,
      agent_id,
      &%{&1 | token_usage: &1.token_usage + tokens, cost_usd: &1.cost_usd + cost_usd}
    )
  end

  @doc "Increment the escalation counter (model tier up-shift) for an agent."
  @spec increment_escalation(String.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found}
  def increment_escalation(team_id, agent_id) do
    update(team_id, agent_id, &%{&1 | escalation_count: &1.escalation_count + 1})
  end

  @doc """
  Apply `fun` to an agent's record atomically.

  Retries on a lost compare-and-swap; returns `{:error, :not_found}` when the
  agent has no row and `{:error, :contended}` if the row could not be claimed
  within the retry budget (only reachable under pathological contention).
  """
  @spec update(String.t(), String.t(), (t() -> t())) ::
          {:ok, t()} | {:error, :not_found | :contended}
  def update(team_id, agent_id, fun) when is_function(fun, 1) do
    TableRegistry.ensure_tables(team_id)
    do_update(team_id, agent_id, fun, 50)
  end

  defp do_update(_team_id, _agent_id, _fun, 0), do: {:error, :contended}

  defp do_update(team_id, agent_id, fun, retries) do
    case get(team_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        updated = fun.(state)
        key = TableRegistry.agent_key(team_id, agent_id)

        spec = [{{key, state}, [], [{{{:const, key}, {:const, updated}}}]}]

        case :ets.select_replace(TableRegistry.agents_table(), spec) do
          1 -> {:ok, updated}
          _ -> do_update(team_id, agent_id, fun, retries - 1)
        end
    end
  rescue
    _ -> {:error, :not_found}
  end
end
