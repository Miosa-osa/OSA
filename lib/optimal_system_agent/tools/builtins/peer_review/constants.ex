defmodule OptimalSystemAgent.Tools.Builtins.PeerReview.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other peer tools (`peer_claim_region`, `peer_negotiate_task`,
  `cross_team_query`) reference `tool_name/0` so a rename here
  propagates automatically.
  """

  @tool_name "peer_review"
  def tool_name, do: @tool_name

  @actions ["request", "check", "submit"]
  def actions, do: @actions

  @verdicts ["approve", "request_changes", "reject"]
  def verdicts, do: @verdicts
end
