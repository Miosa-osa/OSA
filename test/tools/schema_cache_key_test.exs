defmodule OptimalSystemAgent.Tools.SchemaCacheKeyTest do
  @moduledoc """
  Anthropic prompt-caches the tool schema array by prefix match. The cache
  hits only when the JSON bytes are identical. `Tools.schema_cache_key/1`
  is the stable fingerprint of that array: same tools in the same order
  produce the same key; a shuffle does not.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools

  defp tool(name, opts \\ []) do
    %{
      name: name,
      description: Keyword.get(opts, :description, "desc #{name}"),
      parameters:
        Keyword.get(opts, :parameters, %{
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}}
        })
    }
  end

  test "the same tools in the same order produce the same key" do
    tools = [tool("a"), tool("b"), tool("c")]

    assert Tools.schema_cache_key(tools) == Tools.schema_cache_key(tools)
    assert Tools.schema_cache_key(tools) == Tools.schema_cache_key(tools)
    assert is_binary(Tools.schema_cache_key(tools))
    assert byte_size(Tools.schema_cache_key(tools)) == 64
  end

  test "shuffling names produces a different key" do
    a = [tool("a"), tool("b"), tool("c")]
    b = [tool("c"), tool("b"), tool("a")]

    refute Tools.schema_cache_key(a) == Tools.schema_cache_key(b)
  end

  test "a description change produces a different key" do
    a = [tool("a", description: "one")]
    b = [tool("a", description: "two")]

    refute Tools.schema_cache_key(a) == Tools.schema_cache_key(b)
  end

  test "string-keyed and atom-keyed specs of the same schema hash equal" do
    atomish = [
      %{
        name: "file_read",
        description: "Read a file",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]

    stringish = [
      %{
        "name" => "file_read",
        "description" => "Read a file",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert Tools.schema_cache_key(atomish) == Tools.schema_cache_key(stringish)
  end
end
