defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `tool_search`.

  Mirrors upstream:
    * `validate/2`          — type-checks input shape (cheap)
    * `check_permissions/2` — pure registry lookup, always allow
    * `execute/2`           — delegates to Registry.search/2 with formatted output

  The query routing logic mirrors ToolSearchTool.ts `call()`:
    1. `select:A,B,C` prefix — direct comma-separated tool selection
    2. keyword search        — scored name+description match via Registry.search/2

  No side effects. This handler is concurrency-safe by construction:
  it only reads from Registry (ETS-backed persistent_term, no writes).
  """

  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"query" => query} = input, _ctx) when is_binary(query),
    do: {:ok, input}

  def validate(%{"query" => _}, _ctx),
    do: {:error, "query must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: query", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"query" => query} = params, _ctx) do
    max = coerce_max(Map.get(params, "max_results", Constants.default_max_results()))

    case parse_query(query) do
      {:select, names} -> execute_select(names, query)
      {:keyword, q} -> execute_keyword(q, max, query)
    end
  end

  # ── Private: query parsing ────────────────────────────────────────────

  # select:A,B,C — mirrors ToolSearchTool.ts selectMatch branch
  defp parse_query("select:" <> rest) do
    names =
      rest
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:select, names}
  end

  defp parse_query(q), do: {:keyword, q}

  # ── Private: select path ──────────────────────────────────────────────

  defp execute_select([], query),
    do:
      {:ok,
       "No tools found for select query '#{query}'. Provide comma-separated tool names after 'select:'."}

  defp execute_select(names, query) do
    # Get all tools to check whether requested names exist (even already-loaded)
    all_tools =
      OptimalSystemAgent.Tools.Registry.list_tools_direct()
      |> Enum.reduce(%{}, fn tool, acc -> Map.put(acc, tool.name, tool) end)

    {found, missing} =
      Enum.split_with(names, fn name -> Map.has_key?(all_tools, name) end)

    if found == [] do
      {:ok,
       "No matching tools found for select:#{Enum.join(names, ",")}. " <>
         "Unknown: #{Enum.join(missing, ", ")}. Use keyword search to discover tool names."}
    else
      matched_tools = Enum.map(found, fn name -> Map.fetch!(all_tools, name) end)

      suffix =
        if missing != [],
          do: "\n\nNote: #{Enum.join(missing, ", ")} not found in registry.",
          else: ""

      {:ok, format_results(matched_tools, query) <> suffix}
    end
  end

  # ── Private: keyword path ─────────────────────────────────────────────

  defp execute_keyword(query, max, original_query) do
    results = OptimalSystemAgent.Tools.Registry.search(original_query, limit: max)

    if results == [] do
      {:ok,
       "No tools found matching '#{original_query}'. " <>
         "Try broader keywords or 'select:ToolName' for exact lookup."}
    else
      {:ok, format_results(results, query)}
    end
  end

  # ── Private: formatting ───────────────────────────────────────────────

  defp format_results(tools, query) do
    formatted =
      tools
      |> Enum.map(&format_tool/1)
      |> Enum.join("\n---\n")

    "Found #{length(tools)} tool(s) for '#{query}':\n\n#{formatted}"
  end

  defp format_tool(tool) do
    params_desc =
      case tool.parameters do
        %{"properties" => props} when map_size(props) > 0 ->
          props
          |> Enum.map(fn {k, v} ->
            "  #{k}: #{v["type"] || "any"} — #{v["description"] || ""}"
          end)
          |> Enum.join("\n")

        _ ->
          "  (no parameters)"
      end

    required =
      case tool.parameters do
        %{"required" => req} when is_list(req) and req != [] ->
          "Required: #{Enum.join(req, ", ")}"

        _ ->
          ""
      end

    required_line = if required != "", do: "\n#{required}", else: ""

    """
    ## #{tool.name}
    #{tool.description}

    Parameters:
    #{params_desc}#{required_line}
    """
  end

  defp coerce_max(n) when is_integer(n) and n > 0, do: n
  defp coerce_max(_), do: Constants.default_max_results()
end
