defmodule OptimalSystemAgent.MCP.Client.ToolBridge do
  @moduledoc """
  Pure translation layer between MCP tool schemas and OSA's tool registry.

  Two responsibilities:

    * `build_tools/3` — turn a server's raw MCP tool schemas into the OSA
      `mcp_tools` map, keyed by the `mcp__<server>__<tool>` convention, with
      `should_defer?: true` so MCP tools stay out of the base system prompt and
      are surfaced on demand via `tool_search`. A server's `tool_filter`
      allowlist is enforced here so unlisted tools are never exposed.

    * `call/2` — given a prefixed tool name and arguments, parse out the server
      and original tool name, invoke the `ServerSession`, and normalize the
      MCP `content[]` result into OSA's tool-result shape.

  Naming: `mcp__<server>__<tool>` (double underscore as separator). The server
  segment is already sanitized to `[a-z0-9_]` by `MCP.Config`.
  """

  require Logger

  alias OptimalSystemAgent.MCP.Client.ServerSession
  alias OptimalSystemAgent.MCP.Client.OutputLimiter
  alias OptimalSystemAgent.MCP.Protocol.Messages

  @prefix "mcp__"
  @sep "__"

  @doc """
  Build the OSA `mcp_tools` map fragment for one server's tool schemas.

  `tool_filter` is the server's configured allowlist (config `tools` /
  `tool_filter`). When set, only tools whose original name appears in the
  allowlist are exposed to the agent; a `nil` filter exposes every discovered
  tool. An explicit empty allowlist (`[]`) exposes none — the filter is
  fail-closed so a mis-scoped allowlist never leaks unlisted tools.
  """
  @spec build_tools(String.t(), [map()], [String.t()] | nil) :: %{String.t() => map()}
  def build_tools(server_name, schemas, tool_filter \\ nil) when is_list(schemas) do
    allowed? = filter_predicate(tool_filter)

    if valid_server_segment?(server_name) do
      schemas
      |> Enum.map(fn schema -> build_entry(server_name, schema) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn {_key, entry} -> allowed?.(entry.original_name) end)
      |> reject_collisions(server_name)
    else
      Logger.warning(
        "[MCP.ToolBridge] Skipping every tool from server #{inspect(server_name)}: the " <>
          "sanitized server name contains #{inspect(@sep)}, which makes its tool keys " <>
          "ambiguous with another server's. Rename the server."
      )

      %{}
    end
  end

  @doc """
  True when `server_name` can appear in a tool key unambiguously.

  `mcp__<server>__<tool>` is only injective while the server segment cannot
  itself contain `__`: server `a__b` + tool `c` and server `a` + tool `b__c`
  both render as `mcp__a__b__c`. `parse_key/1` splits on the first `__`, so the
  second reading always wins — a tool would route to the wrong server, and
  `Permissions`, which parses the same key, would grant a rule scoped to `a`
  over a tool owned by `a__b`. `MCP.Config.sanitize_name/1` collapses `_` runs
  so this cannot arise from config; this is the fail-closed backstop.
  """
  @spec valid_server_segment?(term()) :: boolean()
  def valid_server_segment?(name) when is_binary(name) do
    name != "" and not String.contains?(name, @sep)
  end

  def valid_server_segment?(_), do: false

  # Two schemas that render to the same key are ambiguous — there is no way to
  # tell which one an invocation meant. `Map.new/1` would resolve that
  # last-write-wins and silently register the loser's name against the winner's
  # schema. Drop every member of a colliding group instead, and say so.
  defp reject_collisions(entries, server_name) do
    {kept, dropped} =
      entries
      |> Enum.group_by(fn {key, _entry} -> key end)
      |> Enum.split_with(fn {_key, group} -> length(group) == 1 end)

    for {key, _} <- dropped do
      Logger.warning(
        "[MCP.ToolBridge] Dropping ambiguous tool key #{inspect(key)} from server " <>
          "#{inspect(server_name)}: more than one discovered tool renders to it."
      )
    end

    Map.new(kept, fn {key, [entry]} -> {key, elem(entry, 1)} end)
  end

  @doc """
  The `mcp__<server>__<tool>` key for a server/tool pair.

  Callers that register keys must gate on `valid_server_segment?/1` first —
  see its docs for why a server segment containing `__` has no unambiguous key.
  """
  @spec tool_key(String.t(), String.t()) :: String.t()
  def tool_key(server_name, tool_name) do
    @prefix <> server_name <> @sep <> tool_name
  end

  @doc """
  Parse a prefixed tool name into `{:ok, {server, tool}}` or `:error`.

  The tool segment may itself contain `__`, so we split on the FIRST `__`
  after the server segment: `mcp__srv__a__b` → `{"srv", "a__b"}`.
  """
  @spec parse_key(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_key(@prefix <> rest) do
    case String.split(rest, @sep, parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, {server, tool}}
      _ -> :error
    end
  end

  def parse_key(_), do: :error

  @doc "Whether a tool name uses the MCP prefix."
  @spec mcp_tool?(String.t()) :: boolean()
  def mcp_tool?(name) when is_binary(name), do: String.starts_with?(name, @prefix)
  def mcp_tool?(_), do: false

  @doc """
  Execute an MCP tool by its prefixed name.

  Returns OSA's tool-result shape:
    * `{:ok, binary}` — text result
    * `{:ok, {:image, %{media_type, data, path}}}` — image result
    * `{:error, reason}`
  """
  @spec call(String.t(), map()) ::
          {:ok, binary()} | {:ok, {:image, map()}} | {:error, term()}
  def call(prefixed_name, arguments) do
    case parse_key(prefixed_name) do
      {:ok, {server, tool}} ->
        do_call(server, tool, arguments || %{})

      :error ->
        {:error, "Invalid MCP tool name: #{prefixed_name}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Extracted for testability: the ServerSession module is looked up at call
  # time so tests can supply a canned session module via the app env.
  defp do_call(server, tool, arguments) do
    session_mod =
      Application.get_env(:optimal_system_agent, :mcp_server_session, ServerSession)

    case session_mod.call_tool(server, tool, strip_internal(arguments)) do
      {:ok, result} ->
        result
        |> Messages.normalize_tool_result()
        |> OutputLimiter.limit(server, tool)
      {:error, reason} -> {:error, mcp_error_message(reason)}
    end
  end

  defp build_entry(_server_name, schema) when not is_map(schema), do: nil

  defp build_entry(server_name, schema) do
    original = schema["name"]

    if is_binary(original) and original != "" do
      key = tool_key(server_name, original)

      {key,
       %{
         original_name: original,
         server: server_name,
         description: schema["description"] || "MCP tool #{original} on #{server_name}",
         input_schema: schema["inputSchema"] || %{"type" => "object", "properties" => %{}},
         annotations: normalize_annotations(schema["annotations"]),
         should_defer?: true
       }}
    else
      nil
    end
  end

  # Turn a `tool_filter` allowlist into a membership predicate over original
  # tool names. `nil` means "no filter configured" → expose everything; any
  # list (including `[]`) is an explicit allowlist → expose only listed names.
  defp filter_predicate(nil), do: fn _name -> true end

  defp filter_predicate(list) when is_list(list) do
    allowed = MapSet.new(list)
    fn name -> MapSet.member?(allowed, name) end
  end

  # Drop OSA-injected internal args (e.g. __session_id__) before forwarding
  # to the remote server.
  defp strip_internal(arguments) when is_map(arguments) do
    arguments
    |> Enum.reject(fn {k, _v} ->
      key = to_string(k)
      String.starts_with?(key, "__") and String.ends_with?(key, "__")
    end)
    |> Map.new()
  end

  defp strip_internal(other), do: other

  # Normalize MCP tool annotations into a stable boolean map. Missing/invalid
  # annotations default to false (treated as write-capable / closed-world).
  defp normalize_annotations(annotations) when is_map(annotations) do
    %{
      read_only: annotations["readOnlyHint"] == true,
      destructive: annotations["destructiveHint"] == true,
      open_world: annotations["openWorldHint"] == true
    }
  end

  defp normalize_annotations(_), do: %{read_only: false, destructive: false, open_world: false}

  defp mcp_error_message({:mcp_error, %{message: message}}) when is_binary(message),
    do: "MCP error: #{message}"

  defp mcp_error_message(:not_ready), do: "MCP server not ready"
  defp mcp_error_message(:timeout), do: "MCP tool call timed out"
  defp mcp_error_message(reason) when is_binary(reason), do: reason
  defp mcp_error_message(reason), do: "MCP tool error: #{inspect(reason)}"
end
