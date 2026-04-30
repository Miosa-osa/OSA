defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  The `cross_team_query` ETS table name is centralised here so
  `CrossTeamQuery.Handler` and test helpers reference the same atom.
  """

  @tool_name "cross_team_query"
  def tool_name, do: @tool_name

  @actions ["ask", "poll", "answer", "list"]
  def actions, do: @actions

  # ETS table used by Peer.Discovery for query storage
  @peer_queries_table :osa_peer_queries
  def peer_queries_table, do: @peer_queries_table
end
