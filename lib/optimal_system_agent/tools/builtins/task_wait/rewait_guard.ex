defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.RewaitGuard do
  @moduledoc """
  Anti-burn guard for `task_wait` (item 6, live-evidence hardening).

  Observed on a real 2h52m session: the loop called `task_wait` on the SAME
  still-running agent (`hipaa-review`, which took 37 min), hit the join-barrier
  ceiling, was told "healthy, do NOT wait again — you'll be notified", and then
  IGNORED that and re-called `task_wait` 4+ times, each re-arming a full ceiling.
  The parent burned repeated blocking waits across the whole session.

  The blocking-wait ceiling is bounded so no single call freezes the parent turn
  for the agent's whole lifetime. This guard closes the other half: once a wait
  times out with an agent still running, that (caller, agent) pair is recorded as
  "already warned". A subsequent `task_wait` whose requested agents are ALL still
  running AND ALL already-warned does NOT arm another blocking wait — it returns
  fast with "already waiting, you'll be notified", so a model that ignores the
  guidance can no longer burn turn after turn on re-arms.

  A warning is short-lived (TTL) and only matters while the agent is still
  running — once it reaches a terminal state the normal path returns its result
  instantly, so the guard never hides a finished result.

  Self-contained ETS registry keyed by `{session_id, agent_id}`, mirroring
  `TaskWait.Depth`.
  """

  @table :task_wait_rewait_warned
  # A warning older than this is ignored (defensive: a session that goes quiet
  # then legitimately re-converges much later should not be silently fast-failed).
  @default_ttl_ms 60 * 60 * 1000

  @doc "Configured warning TTL in ms."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    Application.get_env(:optimal_system_agent, :task_wait_rewait_ttl_ms, @default_ttl_ms)
  end

  @doc """
  Record each `agent_id` as "already warned for this caller" (call after a wait
  times out with those agents still running).
  """
  @spec mark_warned(String.t(), [String.t()]) :: :ok
  def mark_warned(session_id, agent_ids) when is_binary(session_id) and is_list(agent_ids) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    Enum.each(agent_ids, fn id -> :ets.insert(@table, {{session_id, id}, now}) end)
    :ok
  end

  def mark_warned(_, _), do: :ok

  @doc "True when `{session_id, agent_id}` was warned within the TTL."
  @spec warned?(String.t(), String.t()) :: boolean()
  def warned?(session_id, agent_id) when is_binary(session_id) and is_binary(agent_id) do
    ensure_table()

    case :ets.lookup(@table, {session_id, agent_id}) do
      [{_, at}] -> System.monotonic_time(:millisecond) - at <= ttl_ms()
      _ -> false
    end
  end

  def warned?(_, _), do: false

  @doc "Drop any warning for `{session_id, agent_id}` (e.g. once it finishes)."
  @spec clear(String.t(), String.t()) :: :ok
  def clear(session_id, agent_id) when is_binary(session_id) and is_binary(agent_id) do
    ensure_table()
    :ets.delete(@table, {session_id, agent_id})
    :ok
  end

  def clear(_, _), do: :ok

  @doc false
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
