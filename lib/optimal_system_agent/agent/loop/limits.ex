defmodule OptimalSystemAgent.Agent.Loop.Limits do
  @moduledoc """
  Budget and turn-limit policy for the agent loop.

  Extracted from `Loop.check_limits/1` so the per-turn budget and turn-count
  ceilings live in one place instead of inline in the process-message callback.
  Emits the same `:budget_limit_reached` / `:turn_limit_reached` system events
  on the Bus and returns identical error strings.
  """
  alias OptimalSystemAgent.Events.Bus

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

      if current >= max do
        Bus.emit(:system_event, %{
          event: :budget_limit_reached,
          session_id: Map.get(state, :session_id),
          current_cost: current,
          limit: max
        })

        "Budget limit reached ($#{Float.round(current / 1, 4)} / $#{max})"
      end
    end
  end

  defp current_cost(state) do
    case Map.get(state, :session_cost_usd, 0.0) do
      n when is_number(n) -> n
      _ -> 0.0
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
