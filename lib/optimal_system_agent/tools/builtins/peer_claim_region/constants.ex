defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Peer tools (`peer_review`, `peer_negotiate_task`) reference `tool_name/0`
  so a rename here propagates automatically.
  """

  @tool_name "peer_claim_region"
  def tool_name, do: @tool_name

  @actions ["claim", "release", "list", "touch"]
  def actions, do: @actions

  # Region claim expires after 10 minutes of inactivity.
  @claim_ttl_seconds 600
  def claim_ttl_seconds, do: @claim_ttl_seconds
end
