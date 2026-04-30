defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.UI do
  @moduledoc "Render maps for the Rust TUI — enter_worktree."

  def render(:tool_use, %{"branch" => branch} = input, _opts) do
    %{kind: "enter_worktree", branch: branch, path: Map.get(input, "path")}
  end

  def render(:tool_use, input, _opts) do
    %{kind: "enter_worktree", path: Map.get(input, "path")}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "enter_worktree_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "enter_worktree_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
