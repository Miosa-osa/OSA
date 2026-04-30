defmodule OptimalSystemAgent.Tools.Builtins.ListAgents.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool
    * `:tool_result` — successful roster response
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    role = Map.get(input || %{}, "role")

    %{
      kind: "list_agents",
      role: role
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "list_agents_result",
      bytes: byte_size(content)
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "list_agents_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
