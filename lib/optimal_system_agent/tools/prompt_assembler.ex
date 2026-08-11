defmodule OptimalSystemAgent.Tools.PromptAssembler do
  @moduledoc """
  Assembles the tool-section of the system prompt by calling each tool's
  `prompt/1` (with cross-tool references resolved) and partitioning the
  set into loaded vs. deferred (deferred = name only).

  Mirrors the assembly pattern at upstream

  The assembler is byte-deterministic for a fixed input — same tools in,
  same string out. This is the foundation for system-prompt caching
  (see Heatmap Priority 3 in `tasks/tool-harness-plan.md`).

  ## Output

      {loaded_section :: String.t(), deferred_names :: [String.t()]}

  The caller assembles the loaded section into the system prompt and
  emits the deferred names in a `<system-reminder>` block at the top of
  the conversation, advertising tools that can be loaded via ToolSearch.
  """

  alias OptimalSystemAgent.Tools.{LegacyAdapter, UseContext}

  @doc """
  Returns `{loaded_section, deferred_names}` for the given tool modules
  under the given context.

  Tools are filtered to availability, then partitioned by `should_defer?/0`
  (with `always_load?/0` overriding to force-include). Loaded tools have
  their full `prompt/1` body rendered. Deferred tools contribute only
  their name + search_hint.

  ## Options

    * `:only` — allowlist predicate on the tool name (see `partition/2`).
    * `:native_schema_names` — a `MapSet` of tool names whose FULL schema the
      transport will carry natively in this request (description + parameters).
      For those tools the assembler drops the spans that would be byte-for-byte
      duplicates of the native schema and keeps only what the native channel
      cannot express. Omit it (or pass `nil`) to render everything, which is
      what a transport with no native tool channel needs.
  """
  @spec assemble([module()], UseContext.t(), keyword()) ::
          {String.t(), [String.t()]}
  def assemble(tool_modules, %UseContext{} = ctx, opts \\ []) do
    available = Enum.filter(tool_modules, &available?/1)
    only = Keyword.get(opts, :only)
    {loaded, deferred} = partition(available, only)

    loaded_section =
      loaded
      |> Enum.sort_by(& &1.name())
      |> Enum.map(&render_loaded(&1, ctx, available, opts))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    deferred_names =
      deferred
      |> Enum.sort_by(& &1.name())
      |> Enum.map(&format_deferred(&1))

    {loaded_section, deferred_names}
  end

  @doc """
  Partition a tool list into `{loaded, deferred}`.

  A tool is deferred iff `LegacyAdapter.deferred?/1` is true AND
  `LegacyAdapter.always_load?/1` is false. `always_load?` always wins.
  """
  @spec partition([module()]) :: {[module()], [module()]}
  def partition(tools), do: partition(tools, nil)

  @doc """
  Partition with an optional `only` allowlist predicate (`fn tool_name -> boolean`).

  Base rule (unchanged): a tool is loaded iff NOT `deferred?`, OR `always_load?`
  overrides. When `only` is a 1-arity function, that result is further
  INTERSECTED with the allowlist — any tool whose name fails `only` is forced to
  the deferred side regardless of `always_load?`, so it still appears in the
  `<system-reminder>` and stays reachable via tool_search. Passing `nil`
  reproduces the original `partition/1` behavior exactly.
  """
  @spec partition([module()], (String.t() -> boolean()) | nil) :: {[module()], [module()]}
  def partition(tools, only) do
    Enum.split_with(tools, fn mod ->
      base_loaded = not LegacyAdapter.deferred?(mod) or LegacyAdapter.always_load?(mod)

      if is_function(only, 1) do
        base_loaded and only.(mod.name())
      else
        base_loaded
      end
    end)
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp available?(mod) do
    cond do
      function_exported?(mod, :available?, 0) -> mod.available?()
      true -> true
    end
  end

  defp render_loaded(mod, ctx, all_tools, opts) do
    prompt_body =
      if function_exported?(mod, :prompt, 1) do
        mod.prompt(ctx: ctx, tools: all_tools, agents: ctx.agents)
      else
        mod.description()
      end

    if native_schema?(mod, opts) do
      render_native(mod, prompt_body)
    else
      """
      ## #{mod.name()}#{aliases_suffix(mod)}
      #{prompt_body}

      Parameters: #{Jason.encode!(mod.parameters())}
      """
    end
  end

  # The transport already carries this tool's `description/0` and
  # `parameters/0`. Two spans of the prose rendering are therefore pure
  # duplicates of bytes the model receives anyway:
  #
  #   * the `description/0` text, wherever it appears inside `prompt/1`'s body
  #   * the `Parameters: <json>` line, which is `parameters/0` re-encoded
  #
  # Everything ELSE that `prompt/1` produces is content that exists nowhere in
  # the native schema, so it is kept verbatim. Subtracting the description as a
  # SPAN rather than assuming `prompt/1 == description/0` is what makes this
  # safe for a tool whose prompt is a superset of its description: the extra
  # sections survive, and only the repeated span goes. When nothing survives,
  # the tool contributes no block at all — its full documentation is in the
  # tool definitions.
  defp render_native(mod, prompt_body) do
    residual =
      prompt_body
      |> subtract_span(safe_description(mod))
      |> String.trim()

    if residual == "" do
      ""
    else
      "## #{mod.name()}#{aliases_suffix(mod)}\n#{residual}\n"
    end
  end

  defp subtract_span(body, ""), do: body
  defp subtract_span(body, nil), do: body

  defp subtract_span(body, description) do
    if String.contains?(body, description) do
      # Replace only the FIRST occurrence — a description that legitimately
      # recurs (an example echoing the summary line) keeps its later copies.
      String.replace(body, description, "", global: false)
    else
      body
    end
  end

  defp safe_description(mod) do
    if function_exported?(mod, :description, 0), do: mod.description(), else: nil
  rescue
    _ -> nil
  end

  defp native_schema?(mod, opts) do
    case Keyword.get(opts, :native_schema_names) do
      nil -> false
      names -> MapSet.member?(names, mod.name())
    end
  end

  defp aliases_suffix(mod) do
    case LegacyAdapter.normalize(mod) do
      %{aliases: []} -> ""
      %{aliases: list} -> " (aliases: " <> Enum.join(list, ", ") <> ")"
    end
  end

  # Mirrors the deferred-tool format string at
  # upstream.
  defp format_deferred(mod) do
    case LegacyAdapter.normalize(mod) do
      %{search_hint: ""} -> mod.name()
      %{search_hint: hint} -> "#{mod.name()} — #{hint}"
    end
  end
end
