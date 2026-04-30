defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Peer tools (`peer_review`, `peer_claim_region`) reference `tool_name/0`
  so a rename here propagates automatically.
  """

  @tool_name "peer_negotiate_task"
  def tool_name, do: @tool_name

  @actions ["counter", "accept", "reject", "status"]
  def actions, do: @actions
end
