defmodule OptimalSystemAgent.Tools.Builtins.TeamDelete.Prompt do
  @moduledoc "Dynamic prompt for the team_delete tool."

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Dissolve an agent team and reclaim all its resources.

    This is a destructive, irreversible operation. It terminates all agent processes
    in the team, recursively dissolves all child sub-teams (depth-first), tears down
    ETS state tables, and broadcasts a `:team_dissolved` PubSub event.

    Required:
    - `team_id` — the identifier returned by `team_create`

    If the team_id is not found the call is a no-op (returns confirmation).

    Use this when a team's goal is complete, the team hit a budget ceiling, or
    the agent chain needs to be unwound before starting fresh.

    Warning: any in-flight agent work is discarded without a checkpoint.
    """
  end
end
