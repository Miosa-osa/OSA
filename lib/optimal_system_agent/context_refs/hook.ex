defmodule OptimalSystemAgent.ContextRefs.Hook do
  @moduledoc "user_prompt_submit hook that expands @ref tokens in user messages."

  alias OptimalSystemAgent.ContextRefs.{Parser, Resolver}

  @spec user_prompt_submit(map()) :: {:ok, map()} | :skip
  def user_prompt_submit(%{message: message} = payload) when is_binary(message) do
    unless OptimalSystemAgent.Settings.get("context_refs_enabled", true) do
      {:ok, payload}
    else
      working_dir = Map.get(payload, :working_dir)

      case Parser.parse(message, working_dir: working_dir) do
        {_cleaned, []} ->
          :skip

        {cleaned, refs} ->
          blocks = Resolver.resolve(refs, working_dir: working_dir)
          expanded = cleaned <> Resolver.format_blocks(blocks)
          {:ok, %{payload | message: expanded}}
      end
    end
  end

  def user_prompt_submit(_payload), do: :skip
end
