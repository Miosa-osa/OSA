defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Prompt do
  @moduledoc """
  Dynamic prompt for `cross_team_query`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Send a read-only question to another team and get a response.

    Use to consult experts in another team without crossing work boundaries.
    This tool does not assign work — information exchange only.

    Actions:
    - `ask`    — send a question to a target team (async; returns a `query_id`).
    - `poll`   — check whether a query has been answered yet.
    - `answer` — (for receiving-team agents) post an answer to a query.
    - `list`   — list all pending queries directed at your team.

    Boundary enforcement:
    - Answering a query does not commit any work on the receiving team.
    - Any follow-on action requires the receiving team's orchestrator to
      create a new task independently.
    """
  end
end
