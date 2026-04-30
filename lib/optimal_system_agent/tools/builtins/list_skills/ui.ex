defmodule OptimalSystemAgent.Tools.Builtins.ListSkills.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — listing returned
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, _input, _opts) do
    %{kind: "list_skills"}
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "list_skills_result",
      content: content
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "list_skills_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
