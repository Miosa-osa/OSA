defmodule OptimalSystemAgent.ContextRefs.Resolvers.Staged do
  @moduledoc "Resolves @staged by running `git diff --cached` (staged changes)."

  @spec resolve(pos_integer()) :: {:ok, map()} | {:error, map()}
  def resolve(budget) do
    case System.cmd("git", ["diff", "--cached"], stderr_to_stdout: true) do
      {output, 0} ->
        truncated = String.slice(output, 0, budget)
        content = if truncated == "", do: "[No staged changes]", else: "```diff\n#{truncated}\n```"
        {:ok, %{type: :staged, source: "@staged", content: content}}

      {err, _} ->
        {:error,
         %{
           type: :error,
           source: "@staged",
           content: "[git diff --cached failed: #{String.slice(err, 0, 200)}]"
         }}
    end
  end
end
