defmodule OptimalSystemAgent.Agent.Loop.Limits do
  @moduledoc """
  Budget and turn-limit policy for the agent loop.

  Extracted from `Loop.check_limits/1` so the per-turn budget and turn-count
  ceilings live in one place instead of inline in the process-message callback.
  Emits the same `:budget_limit_reached` / `:turn_limit_reached` system events
  on the Bus and returns identical error strings.
  """
  alias OptimalSystemAgent.Agent.SubagentPain
  alias OptimalSystemAgent.Events.Bus

  # Fraction of `max_budget_usd` past which a subagent reports "approaching"
  # pain to its parent (VSM item 9) — mirrors `Agent.Budget`'s own 80%
  # session-wide warning threshold. Purely advisory: it does not itself abort
  # the turn, and it fires at most once per `SubagentPain`'s dedupe window
  # even though `check/1` runs on every iteration.
  @approaching_budget_ratio 0.8

  @doc """
  Check budget and turn limits for the given loop state.

  Returns `nil` when the turn is within limits, or an error string describing
  the first breach (budget takes precedence over turns, matching the original
  inline check).

  Both caps default OFF (`nil`) so long unattended runs are never killed —
  accounting is always on (`Loop.Accounting`), but the cap only bites when a
  caller sets `max_budget_usd` / `max_turns`.
  """
  @spec check(map()) :: String.t() | nil
  def check(state) do
    budget_error = check_budget(state)
    turn_error = check_turns(state)

    budget_error || turn_error
  end

  @doc """
  True when the session has a real budget cap and its accumulated spend has
  reached it. Used both at turn entry (`check/1`) and mid-turn in the ReAct
  loop so a single runaway turn can be aborted, not just the next one.
  """
  @spec budget_exceeded?(map()) :: boolean()
  def budget_exceeded?(state) do
    max = Map.get(state, :max_budget_usd)
    is_number(max) and max > 0 and current_cost(state) >= max
  end

  # Budget check — reads the *real* per-session accumulated spend
  # (`session_cost_usd`, maintained by `Loop.Accounting`). Previously this read
  # a non-existent `total_cost_usd` key off a `{:ok, status}` tuple, so the
  # branch always rescued to `nil` and the cap never fired (dead check).
  defp check_budget(state) do
    max = Map.get(state, :max_budget_usd)

    if is_number(max) and max > 0 do
      current = current_cost(state)

      cond do
        current >= max ->
          Bus.emit(:system_event, %{
            event: :budget_limit_reached,
            session_id: Map.get(state, :session_id),
            current_cost: current,
            limit: max
          })

          report_subagent_pain(state, :budget_exceeded, :critical, current, max)

          "Budget limit reached ($#{Float.round(current / 1, 4)} / $#{max})"

        current >= max * @approaching_budget_ratio ->
          report_subagent_pain(state, :budget_approaching, :warning, current, max)
          nil

        true ->
          nil
      end
    end
  end

  defp current_cost(state) do
    case Map.get(state, :session_cost_usd, 0.0) do
      n when is_number(n) -> n
      _ -> 0.0
    end
  end

  # A subagent (any recursion depth) reports its own budget pressure to its
  # PARENT — `:parent_session_id` is only ever set on a delegated session (see
  # `Orchestrator.run_fresh_subagent/1`'s `subagent_opts`), so a top-level
  # session with no parent to tell simply has nothing to report here.
  defp report_subagent_pain(state, cause, severity, current, max) do
    case Map.get(state, :parent_session_id) do
      parent when is_binary(parent) and parent != "" ->
        session_id = Map.get(state, :session_id, "unknown")

        SubagentPain.report(parent, session_id, cause, severity,
          display_name: Map.get(state, :display_name) || session_id,
          role: Map.get(state, :role),
          detail: %{spent: current, cap: max}
        )

      _ ->
        :ok
    end
  end

  # Turn check
  defp check_turns(state) do
    max_turns = Map.get(state, :max_turns)
    turn_count = Map.get(state, :turn_count, 0)

    if is_integer(max_turns) and max_turns > 0 and turn_count > max_turns do
      Bus.emit(:system_event, %{
        event: :turn_limit_reached,
        session_id: Map.get(state, :session_id),
        turn_count: turn_count,
        limit: max_turns
      })

      "Turn limit reached (#{turn_count}/#{max_turns})"
    end
  end
end
