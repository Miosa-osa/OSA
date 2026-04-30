defmodule OptimalSystemAgent.ContextRefs.Resolvers.GitLog do
  @moduledoc "Resolves @git:N by running `git log --oneline -N`."

  @spec resolve(pos_integer(), pos_integer()) :: {:ok, map()} | {:error, map()}
  def resolve(n, budget) do
    case System.cmd("git", ["log", "--oneline", "-#{n}"], stderr_to_stdout: true) do
      {output, 0} ->
        truncated = String.slice(output, 0, budget)
        {:ok, %{type: :git, source: "@git:#{n}", content: "```\n#{truncated}\n```"}}

      {err, _} ->
        {:error,
         %{
           type: :error,
           source: "@git:#{n}",
           content: "[git log failed: #{String.slice(err, 0, 200)}]"
         }}
    end
  end
end
