defmodule OptimalSystemAgent.Tools.Builtins.UseTool.Handler do
  @moduledoc """
  Validation, permission, and dispatch logic for `use_tool`.

  Dispatch routes through `Tools.Registry.execute/2`, the same authoritative
  entry point the agent loop uses — so the hard safety circuit-breaker and (for
  builtin targets) the full `validate_input → check_permissions → execute`
  pipeline of the *dispatched* tool are enforced. `use_tool` adds no permission
  bypass; it only makes a deferred tool reachable by name.

  Query routing mirrors grok-build's `use_tool`:

    1. Reject meta-tools (`use_tool`, `tool_search`) — dispatching them is
       nonsensical or a discovery step the model should do directly.
    2. Corrective error when the name is ALREADY active (directly callable) —
       steer the model to call it directly instead of wrapping it.
    3. Corrective error when the name is unknown — steer the model back to
       `tool_search` to discover the correct qualified name.
    4. Otherwise dispatch the deferred/virtualized target.
  """

  alias OptimalSystemAgent.Tools.Builtins.UseTool.Constants
  alias OptimalSystemAgent.Tools.{Registry, UseContext}

  # ── Stage 1: validation ───────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"tool_name" => name} = input, _ctx) when is_binary(name) and name != "" do
    case Map.get(input, "tool_input") do
      args when is_map(args) -> {:ok, input}
      nil -> {:ok, Map.put(input, "tool_input", %{})}
      _ -> {:error, "tool_input must be a JSON object", -32_602}
    end
  end

  def validate(%{"tool_name" => _}, _ctx),
    do: {:error, "tool_name must be a non-empty string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: tool_name", -32_602}

  # ── Stage 2: permission ───────────────────────────────────────────────
  # Allow at the dispatcher; the dispatched tool enforces its own permissions.

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, any()} | {:error, String.t()}
  def execute(%{"tool_name" => name} = params, ctx) do
    args = normalize_args(Map.get(params, "tool_input", %{}))

    cond do
      name in Constants.meta_tools() ->
        {:error,
         "use_tool cannot dispatch the meta-tool '#{name}'. " <>
           "Use `tool_search` to discover a tool, then call `use_tool` with that tool's name."}

      MapSet.member?(active_names(), name) ->
        {:error,
         "'#{name}' is already available directly — call it as a normal tool, not through use_tool."}

      not MapSet.member?(known_names(), name) ->
        {:error,
         "Unknown tool '#{name}'. Use `tool_search` to discover the exact qualified name " <>
           "(e.g. \"mcp__<server>__<tool>\") before calling use_tool."}

      true ->
        dispatch(name, args, ctx)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Forward the dispatched call through the authoritative Registry entry point.
  # Session identity is threaded so structured targets can resolve the session;
  # MCP targets strip `__session_id__` before forwarding to the remote server.
  defp dispatch(name, args, ctx) do
    args = maybe_put_session(args, ctx)

    case Registry.execute(name, args) do
      {:ok, _result} = ok -> ok
      {:ok, _result, _meta} = ok -> ok
      {:error, reason} -> {:error, stringify(reason)}
      other -> {:ok, other}
    end
  end

  defp maybe_put_session(args, %UseContext{session_id: sid}) when is_binary(sid),
    do: Map.put_new(args, "__session_id__", sid)

  defp maybe_put_session(args, _ctx), do: args

  # Names of tools that are directly callable (in the model's base toolbox).
  defp active_names do
    Registry.list_active() |> Enum.map(& &1.name) |> MapSet.new()
  end

  # Names of every registered tool, including deferred/virtualized ones.
  defp known_names do
    Registry.list_tools_direct() |> Enum.map(& &1.name) |> MapSet.new()
  end

  # tool_input may arrive as a JSON-encoded string from some providers; decode
  # it to an object when possible, else default to an empty argument map.
  defp normalize_args(args) when is_map(args), do: args

  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_args(_), do: %{}

  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: inspect(reason)
end
