defmodule OptimalSystemAgent.Tools.Builtins.EnterPlanMode.UI do
  @moduledoc "Render maps for the Rust TUI."

  def render(:tool_use, _input, _opts) do
    %{kind: "enter_plan_mode"}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "enter_plan_mode_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "enter_plan_mode_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
