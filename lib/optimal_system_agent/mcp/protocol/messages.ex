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
  #
  # NOTE: this is the ORIGINAL revision, and it is inconsistent with the
  # transport OSA actually uses. `MCP.Transport.Http` implements **Streamable
  # HTTP**, which was introduced in `2025-03-26` and replaced the HTTP+SSE
  # transport that `2024-11-05` defines — the one now marked deprecated. So OSA
  # announces a 2024 protocol while speaking a 2025 transport, and a server
  # that honours the announcement may withhold everything added since.
  #
  # Raising it is a real change, not a string edit: later revisions add
  # capabilities (structured tool output, elicitation, resource links) that a
  # client should not claim without implementing, and OSA's own MCP *server*
  # side reads the same constant. Left at the honest value until that work is
  # done, rather than raised to look current.
  @protocol_version "2024-11-05"

  @doc """
  The MCP revision OSA announces.

  Exposed because the transport must send it in the `MCP-Protocol-Version`
  header on every HTTP request after initialization. Reading it from here
  rather than restating it is what stops the header and the handshake from
  ever disagreeing.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

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

  @doc """
  Build a `tools/list` request, optionally continuing a page with `cursor`.

  A `nil`/empty cursor requests the first page; a non-empty cursor is echoed
  back verbatim to fetch the next page of a paginated listing.
  """
  @spec list_tools(integer() | nil, String.t() | nil) :: map()
  def list_tools(id \\ nil, cursor \\ nil) do
    params =
      case cursor do
        c when is_binary(c) and c != "" -> %{"cursor" => c}
        _ -> %{}
      end

    JSONRPC.request("tools/list", params, id)
  end

  @doc """
  Build a `tools/call` request for `name` with `arguments`.

  When `progress_token` is given it is attached as `params._meta.progressToken`
  so the server MAY emit `notifications/progress` for a long-running call; the
  client uses those to reset its per-call timeout (see `ServerSession`).
  """
  @spec call_tool(String.t(), map(), integer() | nil, term()) :: map()
  def call_tool(name, arguments, id \\ nil, progress_token \\ nil) do
    params = %{"name" => name, "arguments" => arguments || %{}}

    params =
      if is_nil(progress_token),
        do: params,
        else: Map.put(params, "_meta", %{"progressToken" => progress_token})

    JSONRPC.request("tools/call", params, id)
  end

  @doc """
  Extract the opaque pagination cursor from a `tools/list` result, or `nil`.

  A present, non-empty `nextCursor` means more pages remain.
  """
  @spec next_cursor(map()) :: String.t() | nil
  def next_cursor(%{"nextCursor" => c}) when is_binary(c) and c != "", do: c
  def next_cursor(_), do: nil

  @doc """
  Extract the tool list from a `tools/list` result.

  Returns a list of raw MCP tool schema maps (each with `"name"`,
  `"description"`, `"inputSchema"`). Each tool is passed through
  `sanitize_tool/1` so a server that ships a malformed `outputSchema` (an
  unresolvable `$ref`, a non-object, etc.) doesn't take the whole listing
  down — mirrors opencode's schema-tolerant `tools/list` retry.
  """
  @spec parse_tool_list(map()) :: [map()]
  def parse_tool_list(%{"tools" => tools}) when is_list(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.map(&sanitize_tool/1)
  end

  def parse_tool_list(_), do: []

  @doc """
  Defensively sanitize one raw MCP tool schema map.

  Drops an `outputSchema` that is broken — not a JSON-Schema object, or one
  carrying an unresolvable `$ref` — rather than rejecting the tool. `inputSchema`
  is what OSA feeds to the provider, so it is preserved as-is; only the
  optional, frequently-broken `outputSchema` is stripped when unusable.
  """
  @spec sanitize_tool(map()) :: map()
  def sanitize_tool(%{"outputSchema" => schema} = tool) do
    if valid_output_schema?(schema), do: tool, else: Map.delete(tool, "outputSchema")
  end

  def sanitize_tool(tool), do: tool

  # An outputSchema is usable only when it is a JSON-Schema object map. A bare
  # top-level `$ref` (or any `$ref` we can't guarantee resolves) is the classic
  # trigger for provider-side "can't resolve reference" rejections, so treat a
  # top-level `$ref` object as broken and strip it.
  defp valid_output_schema?(schema) when is_map(schema) do
    not Map.has_key?(schema, "$ref")
  end

  defp valid_output_schema?(_), do: false

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
