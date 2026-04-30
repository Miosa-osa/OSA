defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.UI do
  @moduledoc """
  Render maps for the Rust TUI — `peer_negotiate_task`.

  Each `render/3` call returns a structured map the TUI consumes over
  the PubSub event channel. `kind` maps to a TUI component.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "peer_negotiate_task",
      action: action,
      negotiation_id: input["negotiation_id"],
      counter_agent: input["counter_agent"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "peer_negotiate_task_result",
      summary: String.slice(content, 0, 120)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "peer_negotiate_task_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "peer_negotiate_task_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
