defmodule OptimalSystemAgent.Tools.Builtins.PeerReview.UI do
  @moduledoc """
  Render maps for the Rust TUI — `peer_review`.

  Each `render/3` call returns a structured map the TUI consumes over
  the PubSub event channel. `kind` maps to a TUI component.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "peer_review",
      action: action,
      artifact_id: input["artifact_id"],
      reviewer_agent: input["reviewer_agent"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "peer_review_result",
      summary: String.slice(content, 0, 120)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "peer_review_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "peer_review_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
