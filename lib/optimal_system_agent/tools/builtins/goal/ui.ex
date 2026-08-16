defmodule OptimalSystemAgent.Tools.Builtins.Goal.UI do
  @moduledoc "Render maps for the Rust TUI, for `create_goal` / `update_goal`."

  @spec render_create(atom(), any(), keyword()) :: map() | nil

  def render_create(:tool_use, %{"objective" => objective} = input, _opts)
      when is_binary(objective) do
    %{
      kind: "create_goal",
      objective: objective,
      acceptance_criteria: Map.get(input, "acceptance_criteria")
    }
  end

  def render_create(:tool_result, text, _opts) when is_binary(text),
    do: %{kind: "create_goal_result", message: text}

  def render_create(:rejected, _input, _opts), do: %{kind: "create_goal_rejected"}

  def render_create(:error, msg, _opts) when is_binary(msg),
    do: %{kind: "create_goal_error", message: msg}

  def render_create(_stage, _payload, _opts), do: nil

  @spec render_update(atom(), any(), keyword()) :: map() | nil

  def render_update(:tool_use, %{"status" => status}, _opts) when is_binary(status),
    do: %{kind: "update_goal", status: status}

  def render_update(:tool_result, text, _opts) when is_binary(text),
    do: %{kind: "update_goal_result", message: text}

  def render_update(:rejected, _input, _opts), do: %{kind: "update_goal_rejected"}

  def render_update(:error, msg, _opts) when is_binary(msg),
    do: %{kind: "update_goal_error", message: msg}

  def render_update(_stage, _payload, _opts), do: nil
end
