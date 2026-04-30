defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool
    * `:tool_result` — successful operation response
    * `:error`       — execution or validation error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    %{
      kind: "team_tasks",
      action: Map.get(input || %{}, "action"),
      team_id: Map.get(input || %{}, "team_id", "default")
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "team_tasks_result",
      bytes: byte_size(content)
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "team_tasks_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
