defmodule OptimalSystemAgent.ContextRefs.Resolver do
  @moduledoc "Resolves @ref tokens into context blocks within a token budget."

  alias OptimalSystemAgent.ContextRefs.Resolvers

  @type context_block :: %{type: atom(), source: String.t(), content: String.t()}

  @spec resolve([OptimalSystemAgent.ContextRefs.Parser.ref()], keyword()) :: [context_block()]
  def resolve(refs, opts \\ []) do
    budget = Keyword.get(opts, :budget, default_budget())
    working_dir = Keyword.get(opts, :working_dir)

    {blocks, _remaining} =
      Enum.reduce(refs, {[], budget}, fn ref, {acc, remaining} ->
        if remaining <= 0 do
          truncated = %{
            type: :truncated,
            source: "budget",
            content: "[Context truncated: budget exceeded. Remaining @refs skipped.]"
          }

          {acc ++ [truncated], 0}
        else
          case resolve_one(ref, remaining, working_dir) do
            {:ok, block} ->
              used = String.length(block.content)
              {acc ++ [block], remaining - used}

            {:error, block} ->
              {acc ++ [block], remaining}
          end
        end
      end)

    blocks
  end

  @spec format_blocks([context_block()]) :: String.t()
  def format_blocks([]), do: ""

  def format_blocks(blocks) do
    formatted =
      Enum.map_join(blocks, "\n\n", fn block ->
        case block.type do
          :truncated -> block.content
          _ -> "--- #{block.source} ---\n#{block.content}"
        end
      end)

    "\n\n" <> formatted
  end

  defp resolve_one({:file, path, range}, budget, working_dir),
    do: Resolvers.File.resolve(path, range, budget, working_dir)

  defp resolve_one({:diff, _}, budget, _working_dir), do: Resolvers.Diff.resolve(budget)
  defp resolve_one({:staged, _}, budget, _working_dir), do: Resolvers.Staged.resolve(budget)
  defp resolve_one({:git, n}, budget, _working_dir), do: Resolvers.GitLog.resolve(n, budget)
  defp resolve_one({:url, url}, budget, _working_dir), do: Resolvers.Url.resolve(url, budget)

  defp default_budget do
    OptimalSystemAgent.Settings.get("context_refs_budget", 30_000)
  end
end
