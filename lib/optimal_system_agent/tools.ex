defmodule OptimalSystemAgent.Tools do
  @moduledoc """
  Tool-schema helpers shared across the registry, the loop, and providers.

  Anthropic renders a request as `tools` -> `system` -> `messages` and
  prompt-caches by prefix match. The tool schema array is the first bytes
  of that prefix. A cache hit requires identical JSON bytes: same names,
  same descriptions, same parameter schemas, same order.
  """

  @doc """
  Stable SHA-256 hex digest of a tools array. Order is significant.
  """
  @spec schema_cache_key([map()]) :: String.t()
  def schema_cache_key(tools) when is_list(tools) do
    payload = Enum.map(tools, &canonical_tool/1)

    :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp canonical_tool(tool) when is_map(tool) do
    {
      stringify(tool_field(tool, :name, "name")),
      stringify(tool_field(tool, :description, "description")),
      stringify_keys(tool_field(tool, :parameters, "parameters") || %{})
    }
  end

  defp canonical_tool(_), do: {"", "", %{}}

  defp tool_field(tool, atom, string) do
    Map.get(tool, atom, Map.get(tool, string))
  end

  defp stringify(nil), do: ""
  defp stringify(val) when is_binary(val), do: val
  defp stringify(val), do: to_string(val)

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
