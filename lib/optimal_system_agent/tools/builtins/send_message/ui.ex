defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool; TUI shows an outgoing message indicator
    * `:tool_result` — delivery confirmed
    * `:error`       — target not found or delivery failure
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"to" => to, "message" => message}, _opts) do
    %{
      kind: "send_message",
      to: to,
      message: message
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "send_message_result",
      result: result
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "send_message_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
