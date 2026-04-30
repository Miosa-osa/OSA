defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — skill written successfully
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"name" => name} = input, _opts) do
    %{
      kind: "create_skill",
      skill_name: name,
      trigger: input["trigger"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "create_skill_result",
      message: content
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "create_skill_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
