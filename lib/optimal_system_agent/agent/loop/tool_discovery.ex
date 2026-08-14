defmodule OptimalSystemAgent.Agent.Loop.ToolDiscovery do
  @moduledoc """
  Makes a `tool_search` hit actually callable by widening the next request's
  native `tools` array.

  ## The hole this closes

  `Registry.list_active/0` is the sole source of the provider's native `tools`
  array (`filter_applicable_tools/1` -> `Agent.Loop` `state.tools` ->
  `ReactLoop`'s `tools:` option). It consults only `should_defer?`, and
  `ToolFilter.filter/2` can only shrink what it produced. Nothing ever re-added.

  `tool_search` returned a formatted STRING and mutated no state, so the request
  after a search carried exactly the array the request before it did. Under a
  provider with `native_tool_schemas?/0 == true` — which is most real usage —
  the API can only emit a `tool_use` block for a name in that array, so a
  deferred tool was not merely undocumented: it was **uncallable**, and because
  the name could never be emitted there was no "unknown tool" error to make the
  failure visible. Measured on this tree at the time of the fix: 23 of 82
  registered tools were in the array. The generic escape hatch, `use_tool`, was
  itself one of the 59 that were not.

  ## Prefix stability is the constraint, not an afterthought

  Tool schemas render FIRST in an Anthropic request, ahead of `system` and
  `messages`, so they are the front of the cached prefix. Changing them
  mid-session invalidates everything behind them. Three rules keep that cost
  bounded and one-time:

    * **Append only, never reorder.** New specs go on the END of the array, in
      sorted-by-name order. The bytes of every previously sent schema stay where
      they were, which is what lets the provider keep its TOOLS-tier cache
      entry — `Providers.Anthropic.mark_tools_cache_boundary/1` puts the cache
      breakpoint after the last non-discovered tool precisely so a widening
      moves the `system` tier and not the tools tier.
    * **Never shrink back.** `ToolFilter` re-pins anything in
      `state.discovered_tools` that one of its narrowing passes dropped, so a
      tool the model was told it could call does not silently stop being
      callable one iteration later. A tool array that oscillates is worse than
      either of its two states: it invalidates the prefix in BOTH directions.
    * **Idempotent.** A name already in the array produces no change at all, so
      re-running the same search — which models do — costs nothing. Widening
      happens once per genuinely new tool.

  The trade is deliberate and stated: one widening costs one cache write of the
  segments behind the tools array. The alternative is the task failing because
  the model can see a tool it cannot call, and a token saving that costs
  capability is a loss.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler, as: ToolSearch

  # Tool names whose successful result means "the model now knows about these
  # tools". Only `tool_search` today; a list because discovery is a role, not a
  # tool, and `use_tool`-style dispatchers may join it.
  @discovery_tools ~w(tool_search)

  @doc """
  Widen `state.tools` with anything a successful discovery call in `results`
  surfaced. Returns `state` unchanged when nothing new was found.

  `results` is the ReAct loop's `[{tool_call, {message, result_string}}]`. The
  arguments are re-resolved through `ToolSearch.resolve_tools/1` rather than
  parsed back out of the formatted result string: resolution is a pure read of
  the registry, so running it twice is cheap and cannot disagree with what the
  model was shown.
  """
  @spec widen(map(), list()) :: map()
  def widen(state, results) when is_list(results) do
    case newly_discovered(state, results) do
      [] -> state
      specs -> apply_widening(state, specs)
    end
  rescue
    # Discovery is an enhancement on the tool-result path. A malformed argument
    # map must not be able to end a turn that has already done real work.
    error ->
      Logger.debug("[loop] tool discovery skipped: #{inspect(error)}")
      state
  end

  def widen(state, _results), do: state

  @doc "Names currently pinned into the array by discovery."
  @spec discovered_names(map()) :: MapSet.t()
  def discovered_names(state) do
    state
    |> Map.get(:discovered_tools, [])
    |> MapSet.new(&name_of/1)
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp newly_discovered(state, results) do
    known =
      state
      |> Map.get(:tools, [])
      |> MapSet.new(&name_of/1)

    results
    |> Enum.filter(&successful_discovery?/1)
    |> Enum.flat_map(fn {tool_call, _result} ->
      tool_call |> arguments_of() |> ToolSearch.resolve_tools()
    end)
    |> Enum.reject(fn spec -> MapSet.member?(known, name_of(spec)) end)
    |> Enum.uniq_by(&name_of/1)
    # Sorted so the appended bytes are a pure function of WHICH tools were
    # found, not of the order two searches happened to run in.
    |> Enum.sort_by(&name_of/1)
  end

  defp successful_discovery?({tool_call, {_message, result}}) when is_binary(result) do
    name_of(tool_call) in @discovery_tools and not String.starts_with?(result, "Error:")
  end

  defp successful_discovery?(_), do: false

  defp apply_widening(state, specs) do
    marked = Enum.map(specs, &Map.put(&1, :discovered?, true))
    names = Enum.map_join(marked, ", ", &name_of/1)

    Logger.info(
      "[loop] tool discovery: widening the tools array by #{length(marked)} " <>
        "(#{names}) — one prefix invalidation, then stable"
    )

    state
    |> Map.put(:tools, Map.get(state, :tools, []) ++ marked)
    |> Map.put(:discovered_tools, Map.get(state, :discovered_tools, []) ++ marked)
    # `all_tools` is the unfiltered base the coordinator toggle restores from.
    # A discovered tool that is missing there would vanish the moment the user
    # flipped coordinator mode off and on again.
    |> Map.put(:all_tools, Map.get(state, :all_tools, []) ++ marked)
  end

  defp arguments_of(%{arguments: args}) when is_map(args), do: args
  defp arguments_of(%{"arguments" => args}) when is_map(args), do: args
  defp arguments_of(_), do: %{}

  defp name_of(%{name: name}) when is_binary(name), do: name
  defp name_of(%{name: name}) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp name_of(%{"name" => name}) when is_binary(name), do: name
  defp name_of(_), do: ""
end
