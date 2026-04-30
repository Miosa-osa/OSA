defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.UI do
  @moduledoc """
  Render maps for the Rust TUI — `peer_claim_region`.

  Each `render/3` call returns a structured map the TUI consumes over
  the PubSub event channel. `kind` maps to a TUI component.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "peer_claim_region",
      action: action,
      file_path: input["file_path"],
      start_line: input["start_line"],
      end_line: input["end_line"],
      region_id: input["region_id"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "peer_claim_region_result",
      summary: String.slice(content, 0, 120)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "peer_claim_region_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "peer_claim_region_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
