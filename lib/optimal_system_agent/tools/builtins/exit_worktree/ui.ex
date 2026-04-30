defmodule OptimalSystemAgent.Tools.Builtins.ExitWorktree.UI do
  @moduledoc "Render maps for the Rust TUI — exit_worktree."

  def render(:tool_use, %{"path" => path} = input, _opts) do
    %{
      kind: "exit_worktree",
      path: path,
      merge: Map.get(input, "merge", false),
      keep: Map.get(input, "keep", false)
    }
  end

  def render(:tool_use, input, _opts) do
    %{kind: "exit_worktree", path: Map.get(input, "path")}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "exit_worktree_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "exit_worktree_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
