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
  alias OptimalSystemAgent.Tools.Registry
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
      {:server, server} -> execute_server(server, query)
      {:keyword, q} -> execute_keyword(q, max, query)
    end
  end

  @doc """
  The tool SPECS a query resolves to — the same set `execute/2` formats into
  prose, returned as data.

  This exists because formatting them was all `tool_search` ever did. Under a
  provider with native tool schemas the model cannot call a name that is not in
  the request's `tools` array, so a search that only produced a nicely rendered
  description of a deferred tool told the model about something it still had no
  way to invoke. `Agent.Loop.ToolDiscovery` calls this to widen the array for
  subsequent requests, which is what turns a search hit into a callable tool.

  Pure: it reads `persistent_term` snapshots and writes nothing, so it is safe
  to call a second time on the same arguments the handler already ran — and
  that is exactly how the loop uses it, rather than threading a side channel
  out of the tool result.

  Names that do not resolve are simply absent; there is no error case, because
  the caller's question is "what became callable", not "was the query good".
  """
  @spec resolve_tools(map()) :: [map()]
  def resolve_tools(%{"query" => query} = params) when is_binary(query) do
    max = coerce_max(Map.get(params, "max_results", Constants.default_max_results()))

    case parse_query(query) do
      {:select, names} -> select_specs(names)
      {:server, server} -> server_specs(server)
      {:keyword, _q} -> Registry.search(query, limit: max)
    end
  rescue
    _ -> []
  end

  def resolve_tools(_), do: []

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

  # server:<name> — enumerate ONE MCP server's whole toolset.
  #
  # Keyword search returns a scored top-N (default 5), which is useless for
  # "what can this server actually do?" once a server exposes more tools than
  # the cutoff. This form is exhaustive and unranked.
  defp parse_query("server:" <> rest), do: {:server, String.trim(rest)}
  defp parse_query("mcp:" <> rest), do: {:server, String.trim(rest)}

  defp parse_query(q), do: {:keyword, q}

  # ── Private: server path ──────────────────────────────────────────────

  defp execute_server("", _query),
    do: {:ok, "Missing server name. Use `server:<name>`. " <> known_servers_sentence()}

  defp execute_server(server, query) do
    case Registry.mcp_tools_for_server(server) do
      [] ->
        {:ok, "No MCP server named '#{server}' is connected. " <> known_servers_sentence()}

      _entries ->
        {:ok, format_results(server_specs(server), query)}
    end
  end

  # Shared by `execute_server/2` and `resolve_tools/1` so the set the model is
  # TOLD about and the set that becomes callable can never diverge.
  defp server_specs(server) do
    by_name = Map.new(Registry.list_tools_direct(), fn tool -> {tool.name, tool} end)

    server
    |> Registry.mcp_tools_for_server()
    |> Enum.flat_map(fn e -> List.wrap(Map.get(by_name, e.name)) end)
  end

  defp known_servers_sentence do
    case Registry.mcp_servers() do
      [] ->
        "No MCP servers are currently connected."

      servers ->
        "Connected MCP servers: #{Enum.join(servers, ", ")}."
    end
  end

  # ── Private: select path ──────────────────────────────────────────────

  defp execute_select([], query),
    do:
      {:ok,
       "No tools found for select query '#{query}'. Provide comma-separated tool names after 'select:'."}

  defp execute_select(names, query) do
    # Get all tools to check whether requested names exist (even already-loaded)
    all_tools =
      Registry.list_tools_direct()
      |> Enum.reduce(%{}, fn tool, acc -> Map.put(acc, tool.name, tool) end)

    {found, missing} =
      Enum.split_with(names, fn name -> Map.has_key?(all_tools, name) end)

    if found == [] do
      {:ok,
       "No matching tools found for select:#{Enum.join(names, ",")}. " <>
         "Unknown: #{Enum.join(missing, ", ")}. " <>
         near_miss_sentence(missing, Map.keys(all_tools)) <>
         "Next step: run a keyword search (e.g. `tool_search` with a plain word) " <>
         "to discover tool names. " <> known_servers_sentence()}
    else
      matched_tools = select_specs(found)

      suffix =
        if missing != [],
          do: "\n\nNote: #{Enum.join(missing, ", ")} not found in registry.",
          else: ""

      {:ok, format_results(matched_tools, query) <> suffix}
    end
  end

  # Shared by `execute_select/2` and `resolve_tools/1`. Preserves the caller's
  # order and silently drops unknown names — `execute_select/2` reports those
  # separately, and a widening has nothing to say about a name that does not
  # exist.
  defp select_specs(names) do
    by_name = Map.new(Registry.list_tools_direct(), fn tool -> {tool.name, tool} end)

    Enum.flat_map(names, fn name -> List.wrap(Map.get(by_name, name)) end)
  end

  # ── Private: keyword path ─────────────────────────────────────────────

  defp execute_keyword(query, max, original_query) do
    results = Registry.search(original_query, limit: max)

    if results == [] do
      {:ok,
       "No tools found matching '#{original_query}'. " <>
         "Next step: retry with a broader single keyword, or 'select:ToolName' for an " <>
         "exact lookup, or 'server:<name>' to list one MCP server's whole toolset. " <>
         known_servers_sentence()}
    else
      {:ok, format_results(results, query) <> mcp_hint(results)}
    end
  end

  # A keyword search returns a scored top-N. When MCP servers are connected but
  # none of their tools made the cut, say so and name them — otherwise the model
  # reads an all-builtin result list as proof that no MCP tool is relevant.
  defp mcp_hint(results) do
    servers = Registry.mcp_servers()

    shown_mcp? =
      Enum.any?(results, fn t -> String.starts_with?(t.name, "mcp__") end)

    if servers == [] or shown_mcp? do
      ""
    else
      "\n\nAlso connected (no match above the cutoff): MCP servers " <>
        Enum.join(servers, ", ") <>
        ". Use 'server:<name>' to list one server's full toolset."
    end
  end

  # Suggest the closest known tool names for each unmatched request. A typo'd
  # name is the common failure here, and "Unknown: foo" alone gives the model
  # nothing to act on.
  defp near_miss_sentence([], _known), do: ""

  defp near_miss_sentence(missing, known) do
    suggestions =
      missing
      |> Enum.flat_map(fn name ->
        known
        |> Enum.map(fn k ->
          {k, String.jaro_distance(String.downcase(name), String.downcase(k))}
        end)
        |> Enum.filter(fn {_k, score} -> score >= 0.75 end)
        |> Enum.sort_by(fn {_k, score} -> score end, :desc)
        |> Enum.take(2)
        |> Enum.map(fn {k, _} -> k end)
      end)
      |> Enum.uniq()

    case suggestions do
      [] -> ""
      names -> "Closest known names: #{Enum.join(names, ", ")}. "
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
