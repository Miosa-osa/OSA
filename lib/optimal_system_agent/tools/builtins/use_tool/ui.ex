defmodule OptimalSystemAgent.Tools.Builtins.UseTool.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  The tool_use stage shows the dispatched tool name inline; other stages fall
  back to the dispatched tool's own rendering (nil → TUI default).
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"tool_name" => name}, _opts),
    do: %{kind: "use_tool", tool_name: name}

  def render(:error, msg, _opts) when is_binary(msg),
    do: %{kind: "use_tool_error", message: msg}

  def render(_stage, _payload, _opts), do: nil
end
