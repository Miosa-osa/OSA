defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool
    * `:tool_result` — message sent / inbox content
    * `:error`       — execution or validation error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    %{
      kind: "message_agent",
      action: Map.get(input || %{}, "action"),
      to: Map.get(input || %{}, "to"),
      team_id: Map.get(input || %{}, "team_id", "default")
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "message_agent_result",
      bytes: byte_size(content)
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "message_agent_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
