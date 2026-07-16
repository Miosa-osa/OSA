defmodule OptimalSystemAgent.Agent.PlanStore do
  @moduledoc """
  Pending plan index for the plan → approve → execute round-trip.

  When a session produces a plan (plan mode), the plan text and the original
  user input are stashed here keyed by session id. The TUI shows the plan in
  its `plan_review` dialog and then POSTs `plan_approve` / `plan_reject` /
  `plan_edit` to `/commands/execute`. Those handlers read this store to resume
  execution (approve) or revise (edit) without the client having to echo the
  full plan text back.

  Backed by a lazily-created public ETS table so it survives across the
  stateless HTTP request that consumes it, mirroring `RunStore`'s pattern.
  """

  @table :osa_pending_plans

  @type pending :: %{plan: String.t(), input: String.t(), created_at: DateTime.t()}

  @doc "Stash the pending plan and the original user input for a session."
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(session_id, plan, input)
      when is_binary(session_id) and is_binary(plan) and is_binary(input) do
    ensure_table()

    :ets.insert(
      @table,
      {session_id, %{plan: plan, input: input, created_at: DateTime.utc_now()}}
    )

    :ok
  end

  def put(_session_id, _plan, _input), do: :ok

  @doc "Read the pending plan for a session without removing it."
  @spec get(String.t()) :: pending() | nil
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, pending}] -> pending
      [] -> nil
    end
  end

  def get(_), do: nil

  @doc "Read and atomically remove the pending plan for a session."
  @spec take(String.t()) :: pending() | nil
  def take(session_id) when is_binary(session_id) do
    pending = get(session_id)
    if pending, do: :ets.delete(@table, session_id)
    pending
  end

  def take(_), do: nil

  @doc "Drop any pending plan for a session."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  def clear(_), do: :ok

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
