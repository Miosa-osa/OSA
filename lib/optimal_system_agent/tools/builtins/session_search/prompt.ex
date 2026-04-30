defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch.Prompt do
  @moduledoc """
  Dynamic prompt for `session_search`.
  """

  alias OptimalSystemAgent.Tools.Builtins.SessionSearch.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    limit = Constants.default_limit()

    """
    Search past conversation sessions for messages matching a query.

    Uses FTS5 full-text search when available; falls back to legacy memory
    search if the FTS index is not yet populated.

    Results include the session ID, role, timestamp, and a content preview for
    each matching message. Up to #{limit} results are returned by default; pass
    a `limit` parameter to increase or decrease this.

    Use this tool to recall context from earlier sessions — for example, to
    find a previous decision, locate a past implementation, or re-read earlier
    instructions that may have been summarised away.
    """
  end
end
