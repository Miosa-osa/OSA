defmodule OptimalSystemAgent.ContextRefs.Resolvers.Diff do
  @moduledoc "Resolves @diff by running `git diff` (unstaged changes)."

  @spec resolve(pos_integer()) :: {:ok, map()} | {:error, map()}
  def resolve(budget) do
    case OptimalSystemAgent.Git.cmd(["diff"], stderr_to_stdout: true) do
      {output, 0} ->
        truncated = String.slice(output, 0, budget)
        content = if truncated == "", do: "[No unstaged changes]", else: "```diff\n#{truncated}\n```"
        {:ok, %{type: :diff, source: "@diff", content: content}}

      {err, _} ->
        {:error,
         %{
           type: :error,
           source: "@diff",
           content: "[git diff failed: #{String.slice(err, 0, 200)}]"
         }}
    end
  end
end
