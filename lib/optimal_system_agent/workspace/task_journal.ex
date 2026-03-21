defmodule OptimalSystemAgent.Workspace.TaskJournal do
  @moduledoc """
  Append-only log of all task state changes within a workspace.

  Journals are the authoritative audit trail: every transition a task passes
  through is recorded here with who triggered it and why. On workspace restore
  the journal can replay task history without re-running side effects.

  ## Entry structure

      %{
        timestamp:    DateTime.t(),
        workspace_id: String.t(),
        task_id:      String.t(),
        agent_id:     String.t(),
        action:       :created | :assigned | :started | :paused | :completed | :failed | :reassigned,
        details:      map()
      }

  ## Storage

  Entries are appended directly to SQLite via `Workspace.Store.append_journal/1`.
  No in-memory buffer — each `append/2` call is a synchronous SQLite write so
  the journal survives crashes without a flush step.
  """

  require Logger
  alias OptimalSystemAgent.Workspace.Store

  @valid_actions ~w(created assigned started paused completed failed reassigned)a

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Append a task state change to the journal.

  ## Parameters
  - `workspace_id` — owning workspace
  - `entry`        — map with required keys `:task_id`, `:agent_id`, `:action`
                     and optional `:details`

  Returns `:ok` or `{:error, reason}`.
  """
  @spec append(String.t(), map()) :: :ok | {:error, term()}
  def append(workspace_id, %{action: action} = entry)
      when action in @valid_actions do
    record = %{
      workspace_id: workspace_id,
      task_id: Map.get(entry, :task_id, ""),
      agent_id: Map.get(entry, :agent_id, ""),
      action: action,
      details: Map.get(entry, :details, %{}),
      timestamp: DateTime.utc_now()
    }

    case Store.append_journal(record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[TaskJournal] Failed to append #{action} for task #{record.task_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def append(workspace_id, %{action: action} = entry) do
    # Try to coerce string actions to atoms for forward-compat
    case safe_to_action_atom(action) do
      {:ok, atom} -> append(workspace_id, %{entry | action: atom})
      :error -> {:error, "Unknown journal action: #{inspect(action)}. Valid: #{inspect(@valid_actions)}"}
    end
  end

  def append(_workspace_id, entry) do
    {:error, "Journal entry missing :action — got: #{inspect(Map.keys(entry))}"}
  end

  @doc """
  Retrieve journal entries for a workspace.

  ## Options
  - `:task_id`  — filter to a specific task
  - `:agent_id` — filter to a specific agent
  - `:action`   — filter to a specific action atom
  - `:since`    — ISO8601 string lower bound
  - `:until`    — ISO8601 string upper bound
  - `:limit`    — max entries returned (default: 500)

  Returns a list of entry maps in chronological order.
  """
  @spec get_journal(String.t(), keyword()) :: [map()]
  def get_journal(workspace_id, opts \\ []) do
    Store.query_journal(workspace_id, opts)
  end

  @doc """
  Get the full history for a single task.
  Shorthand for `get_journal/2` with `task_id` filter.
  """
  @spec task_history(String.t(), String.t()) :: [map()]
  def task_history(workspace_id, task_id) do
    get_journal(workspace_id, task_id: task_id)
  end

  @doc """
  Get all actions performed by a specific agent in this workspace.
  """
  @spec agent_activity(String.t(), String.t()) :: [map()]
  def agent_activity(workspace_id, agent_id) do
    get_journal(workspace_id, agent_id: agent_id)
  end

  @doc """
  Returns a compact summary of task statuses derived from the journal.

  Replays the journal to find the last action for each task_id.
  Useful for verifying current state matches the audit trail.
  """
  @spec task_summary(String.t()) :: %{String.t() => atom()}
  def task_summary(workspace_id) do
    workspace_id
    |> get_journal()
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.put(acc, entry.task_id, entry.action)
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp safe_to_action_atom(action) when is_atom(action) do
    if action in @valid_actions, do: {:ok, action}, else: :error
  end

  defp safe_to_action_atom(action) when is_binary(action) do
    atom = String.to_existing_atom(action)
    if atom in @valid_actions, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp safe_to_action_atom(_), do: :error
end
