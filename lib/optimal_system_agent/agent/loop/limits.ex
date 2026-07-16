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
  """
  @spec check(map()) :: String.t() | nil
  def check(state) do
    budget_error = check_budget(state)
    turn_error = check_turns(state)

    budget_error || turn_error
  end

  # Budget check
  defp check_budget(state) do
    if state.max_budget_usd do
      try do
        budget = OptimalSystemAgent.Budget.get_status()
        current_cost = (budget[:total_cost_usd] || 0) / 1

        if current_cost >= state.max_budget_usd do
          Bus.emit(:system_event, %{
            event: :budget_limit_reached,
            session_id: state.session_id,
            current_cost: current_cost,
            limit: state.max_budget_usd
          })

          "Budget limit reached ($#{Float.round(current_cost, 4)} / $#{state.max_budget_usd})"
        end
      rescue
        _ -> nil
      end
    end
  end

  # Turn check
  defp check_turns(state) do
    if state.max_turns && state.turn_count > state.max_turns do
      Bus.emit(:system_event, %{
        event: :turn_limit_reached,
        session_id: state.session_id,
        turn_count: state.turn_count,
        limit: state.max_turns
      })

      "Turn limit reached (#{state.turn_count}/#{state.max_turns})"
    end
  end
end
