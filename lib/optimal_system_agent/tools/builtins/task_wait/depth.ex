defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Depth do
  @moduledoc """
  Blocking-wait nesting-depth ceiling for `task_wait` (P5 join-barrier).

  Mirrors grok-build's `parent_blocking_wait_depth` Arc ceiling
  (`subagent/mod.rs:366`): a blocked agent that itself blocks on further
  agents cannot nest arbitrarily deep, which is what makes deadlock/starvation
  from a chain of mutually-waiting agents impossible — the chain is capped.

  This is deliberately self-contained (an ETS registry of "currently blocked"
  agent ids + a walk up `RunStore`'s `parent_session_id` chain) rather than a
  new `UseContext`/`Loop` field, because `delegation_depth` — the closest
  existing analogue — is threaded through `Agent.Loop` init options that this
  feature must not touch. The tradeoff: depth is derived at call time from
  live state instead of being carried on the context struct, which is fine
  for a ceiling check that only needs to be correct at the moment `task_wait`
  is invoked.

  ## How depth is computed

  Every `task_wait` call registers its OWN agent id as "actively blocked" for
  the duration of the wait (`enter/1` .. `exit/1`). `current_depth/1` walks the
  caller's ancestor chain (`RunStore.get(id).parent_session_id`, repeated) and
  counts how many ancestors are ALSO currently registered as blocked — i.e.
  how many `task_wait` calls are already stacked above this one. Adding 1 for
  the call about to happen gives the depth a NEW call would create; that is
  compared against `max_depth/0` in `check_permissions/2` BEFORE the wait
  starts, so a request that would exceed the ceiling is denied outright
  instead of blocking and then failing.
  """

  @table :task_wait_active_waits
  @default_max_depth 3

  @doc """
  Configured maximum blocking-wait nesting depth. Configurable via
    config :optimal_system_agent, :max_blocking_wait_depth, N
  """
  @spec max_depth() :: pos_integer()
  def max_depth do
    Application.get_env(:optimal_system_agent, :max_blocking_wait_depth, @default_max_depth)
  end

  @doc """
  Number of ANCESTORS of `agent_id` currently registered as blocked in a
  `task_wait` call (does not count `agent_id` itself). 0 for a top-level
  session or any agent with no currently-blocked ancestor.
  """
  @spec current_depth(String.t() | nil) :: non_neg_integer()
  def current_depth(agent_id) do
    ensure_table()
    ancestor_blocked_count(agent_id, MapSet.new())
  end

  @doc "Register `agent_id` as actively blocked in a task_wait call."
  @spec enter(String.t()) :: :ok
  def enter(agent_id) when is_binary(agent_id) do
    ensure_table()
    :ets.insert(@table, {agent_id, true})
    :ok
  end

  @doc "Deregister `agent_id` — call unconditionally (e.g. in an `after`) once its wait ends."
  @spec exit_wait(String.t()) :: :ok
  def exit_wait(agent_id) when is_binary(agent_id) do
    ensure_table()
    :ets.delete(@table, agent_id)
    :ok
  end

  @doc false
  # Test/introspection helper — true when `agent_id` is currently registered
  # as blocked.
  @spec blocked?(String.t()) :: boolean()
  def blocked?(agent_id) do
    ensure_table()
    :ets.member(@table, agent_id)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ancestor_blocked_count(nil, _seen), do: 0
  defp ancestor_blocked_count("unknown", _seen), do: 0

  defp ancestor_blocked_count(agent_id, seen) do
    if MapSet.member?(seen, agent_id) do
      # Cycle guard — a corrupted/adversarial parent chain must not hang here.
      0
    else
      case parent_of(agent_id) do
        nil ->
          0

        parent ->
          if :ets.member(@table, parent) do
            1 + ancestor_blocked_count(parent, MapSet.put(seen, agent_id))
          else
            0
          end
      end
    end
  end

  defp parent_of(agent_id) do
    case OptimalSystemAgent.Agent.RunStore.get(agent_id) do
      %{parent_session_id: parent} when is_binary(parent) -> parent
      _ -> nil
    end
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
