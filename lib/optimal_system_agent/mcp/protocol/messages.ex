defmodule OptimalSystemAgent.MCP.Protocol.Messages do
  @moduledoc """
  MCP-specific message builders and result normalization.

  Builds the JSON-RPC payloads for the MCP handshake and tool methods
  (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`)
  and normalizes an MCP `tools/call` result (`content[]` of text / image /
  resource blocks) into OSA's internal tool-result shape as consumed by
  `Agent.Loop.ToolExecutor.execute_tool/2`:

    * `{:ok, binary}`                              — plain text
    * `{:ok, {:image, %{media_type, data, path}}}` — a single image
    * `{:error, reason}`                           — server-reported tool error

  Pure module: builders return maps, normalization is a pure transform.
  """

  alias OptimalSystemAgent.MCP.Protocol.JSONRPC

  # MCP protocol revision OSA speaks. Servers may negotiate down.
  @protocol_version "2024-11-05"

  @client_info %{
    "name" => "osa",
    "version" => "1.0.0"
  }

  @doc "Build the `initialize` request (client → server handshake)."
  @spec initialize(integer() | nil) :: map()
  def initialize(id \\ nil) do
    JSONRPC.request(
      "initialize",
      %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{
          "tools" => %{},
          "roots" => %{"listChanged" => false}
        },
        "clientInfo" => @client_info
      },
      id
    )
  end

  @doc "Build the `notifications/initialized` notification (client → server, post-handshake)."
  @spec initialized() :: map()
  def initialized do
    JSONRPC.notification("notifications/initialized", %{})
  end

  @doc "Build a `tools/list` request."
  @spec list_tools(integer() | nil) :: map()
  def list_tools(id \\ nil) do
    JSONRPC.request("tools/list", %{}, id)
  end

  @doc "Build a `tools/call` request for `name` with `arguments`."
  @spec call_tool(String.t(), map(), integer() | nil) :: map()
  def call_tool(name, arguments, id \\ nil) do
    JSONRPC.request(
      "tools/call",
      %{"name" => name, "arguments" => arguments || %{}},
      id
    )
  end

  @doc """
  Extract the tool list from a `tools/list` result.

  Returns a list of raw MCP tool schema maps (each with `"name"`,
  `"description"`, `"inputSchema"`).
  """
  @spec parse_tool_list(map()) :: [map()]
  def parse_tool_list(%{"tools" => tools}) when is_list(tools), do: tools
  def parse_tool_list(_), do: []

  @doc """
  Normalize an MCP `tools/call` result map into OSA's tool-result shape.

  Handles `isError: true` (→ `{:error, text}`), a lone image block
  (→ `{:ok, {:image, ...}}`), and any mix of text / resource blocks
  (→ `{:ok, joined_text}`).
  """
  @spec normalize_tool_result(map()) ::
          {:ok, binary()} | {:ok, {:image, map()}} | {:error, term()}
  def normalize_tool_result(%{"isError" => true} = result) do
    {:error, join_text(content_blocks(result))}
  end

  def normalize_tool_result(result) when is_map(result) do
    blocks = content_blocks(result)

    case blocks do
      [%{"type" => "image"} = image] ->
        {:ok, normalize_image(image)}

      _ ->
        text = join_text(blocks)

        text =
          if text == "" and blocks != [] do
            # No text blocks but content present (e.g. lone resource): summarize.
            "[MCP result: #{length(blocks)} content block(s)]"
          else
            text
          end

        {:ok, text}
    end
  end

  def normalize_tool_result(_), do: {:ok, ""}

  # ── Private ───────────────────────────────────────────────────────────

  defp content_blocks(%{"content" => content}) when is_list(content), do: content
  defp content_blocks(_), do: []

  # Join text and resource blocks into a single string.
  defp join_text(blocks) do
    blocks
    |> Enum.map(&block_to_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp block_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp block_to_text(%{"type" => "resource", "resource" => resource}) when is_map(resource) do
    cond do
      is_binary(resource["text"]) -> resource["text"]
      is_binary(resource["uri"]) -> "[resource: #{resource["uri"]}]"
      true -> ""
    end
  end

  defp block_to_text(%{"type" => "image"} = image) do
    "[image: #{image["mimeType"] || "image"}]"
  end

  defp block_to_text(_), do: ""

  # Convert an MCP image block into OSA's `{:image, %{media_type, data, path}}`.
  defp normalize_image(%{} = image) do
    {:image,
     %{
       media_type: image["mimeType"] || "image/png",
       data: image["data"] || "",
       path: "mcp-image"
     }}
  end
end
