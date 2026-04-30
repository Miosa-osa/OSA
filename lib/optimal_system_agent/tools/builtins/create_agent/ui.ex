defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool (show agent name being created)
    * `:tool_result` — successful creation confirmation
    * `:error`       — execution or validation error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    %{
      kind: "create_agent",
      name: Map.get(input || %{}, "name"),
      tier: Map.get(input || %{}, "tier", "specialist")
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "create_agent_result",
      bytes: byte_size(content)
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "create_agent_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
