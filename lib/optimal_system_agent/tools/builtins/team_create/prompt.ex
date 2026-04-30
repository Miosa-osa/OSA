defmodule OptimalSystemAgent.Tools.Builtins.TeamCreate.Prompt do
  @moduledoc "Dynamic prompt for the team_create tool."

  alias OptimalSystemAgent.Tools.Builtins.TeamCreate.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Spawn a new agent team to pursue a shared goal in parallel.

    A team is an isolated execution context: it owns a budget, an ETS state store, a
    NervousSystem for coordination primitives, and a roster of named agents. Teams may
    be nested (max depth 3) via the `parent_id` optional field.

    Required:
    - `name`    — human-readable label for the team (max #{Constants.max_name_length()} chars)
    - `members` — list of agent role names from the agent registry (max #{Constants.max_members()})

    Optional:
    - `goal`       — natural-language objective written into team metadata
    - `budget_usd` — USD budget ceiling (default 1.0)
    - `parent_id`  — team_id of an existing team to nest under

    Returns the new `team_id`. Pass it to `team_tasks`, `message_agent`, and
    `team_delete` to manage the team throughout its lifecycle.

    Use `list_agents` first to confirm valid role names — invalid roles are rejected.
    """
  end
end
