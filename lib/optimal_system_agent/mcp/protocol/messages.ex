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

  # MCP protocol revision OSA announces. Servers may negotiate down.
  #
  # ## Why 2025-06-18
  #
  # `MCP.Transport.Http` implements **Streamable HTTP**, introduced in
  # `2025-03-26`, which replaced the HTTP+SSE transport `2024-11-05` defines.
  # Announcing 2024 while speaking a 2025 transport lets a server that honours
  # the announcement withhold everything added since.
  #
  # Of the two candidate revisions, `2025-06-18` is the one OSA can honestly
  # claim, and `2025-03-26` is the one it cannot:
  #
  #   * `2025-03-26` made JSON-RPC **batching** part of the protocol — a
  #     receiver must accept an array of messages. `Protocol.JSONRPC.decode/1`
  #     and `Server.StdioServer` handle exactly one message per frame, so
  #     announcing 2025-03-26 would claim batch handling OSA does not have.
  #   * `2025-06-18` REMOVED batching again, so single-message framing is
  #     conformant there.
  #
  # ## What each revision requires, and what OSA does about it
  #
  # 2025-03-26 over 2024-11-05:
  #
  #   * Streamable HTTP transport      — implemented (`Transport.Http`).
  #   * OAuth 2.1 authorization        — OPTIONAL for a client. OSA does not
  #     implement the MCP OAuth flow (it sends operator-configured static
  #     headers), and declares no authorization capability, so nothing is
  #     claimed. RFC 8707 resource indicators bind on clients that DO speak
  #     OAuth; not applicable.
  #   * JSON-RPC batching              — not implemented; removed again in
  #     2025-06-18, which is why that is the announced revision.
  #   * Tool annotations               — inert metadata on `tools/list` entries;
  #     passed through to the provider untouched. Nothing to implement.
  #   * `ProgressNotification.message`  — progress notifications are consumed
  #     (`ServerSession` re-arms the call timeout on them); the extra
  #     descriptive field is simply ignored, which is legal.
  #   * Audio content blocks           — handled in `normalize_tool_result/1`.
  #   * `completions` capability       — a SERVER capability. OSA's client never
  #     calls `completion/complete`, so it neither needs nor announces it.
  #
  # 2025-06-18 over 2025-03-26:
  #
  #   * No JSON-RPC batching           — matches OSA's framing.
  #   * Structured tool output         — `normalize_tool_result/1` reads
  #     `structuredContent`, and `sanitize_tool/1` already guards `outputSchema`.
  #   * Resource links in tool results — handled in `normalize_tool_result/1`.
  #   * `MCP-Protocol-Version` header  — sent by `Transport.Http` on every
  #     request, sourced from `protocol_version/0` / the negotiated revision.
  #   * Elicitation                    — a CLIENT capability, and OSA has no
  #     path to put an `elicitation/create` form in front of the operator. It is
  #     therefore deliberately NOT announced; a server will simply not use it.
  #   * `_meta` / `title` / completion `context` — additive fields OSA either
  #     passes through or ignores; nothing to claim.
  #
  # Client capabilities announced below are exactly the implemented set:
  # `roots` only. `sampling` is absent (OSA answers no `sampling/createMessage`)
  # and so is `elicitation`. The previous `"tools" => %{}` entry was never a
  # client capability at all — `tools` is declared by SERVERS — so it announced
  # nothing and has been dropped.
  @protocol_version "2025-06-18"

  # Every revision OSA can operate under, newest first. A server may negotiate
  # down to any of these; anything else is refused rather than guessed at.
  # `2024-11-05` stays supported because the legacy HTTP+SSE fallback in
  # `Transport.Http` exists precisely to talk to servers still on it.
  @supported_versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  # Per the transport spec: a server receiving no `MCP-Protocol-Version` header,
  # with no other way to identify the version, SHOULD assume `2025-03-26`.
  @assumed_header_version "2025-03-26"

  @doc """
  The MCP revision OSA announces.

  Exposed because the transport must send it in the `MCP-Protocol-Version`
  header on every HTTP request after initialization. Reading it from here
  rather than restating it is what stops the header and the handshake from
  ever disagreeing.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "Every MCP revision OSA can operate under, newest first."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "Whether `version` is a revision OSA can operate under."
  @spec supports_version?(term()) :: boolean()
  def supports_version?(version) when is_binary(version), do: version in @supported_versions
  def supports_version?(_), do: false

  @doc """
  Resolve the revision to use from a server's `initialize` RESULT (OSA as client).

  The server may negotiate down: it answers with the revision it will speak,
  which need not be the one we asked for. Returns

    * `{:ok, version}` — a revision OSA supports; use it from here on, including
      in the `MCP-Protocol-Version` header.
    * `{:error, {:unsupported_protocol_version, version}}` — the server picked
      something OSA cannot speak. The lifecycle spec says the client SHOULD
      disconnect rather than continue, because every later message would be
      interpreted under a schema neither side agreed on.

  A result with no `protocolVersion` at all is a server not following the
  lifecycle. Rather than inventing a revision, we keep the one we announced —
  which is exactly the state the connection was already in.
  """
  @spec negotiate_version(map()) ::
          {:ok, String.t()} | {:error, {:unsupported_protocol_version, term()}}
  def negotiate_version(%{"protocolVersion" => version}) when is_binary(version) do
    if supports_version?(version),
      do: {:ok, version},
      else: {:error, {:unsupported_protocol_version, version}}
  end

  def negotiate_version(%{"protocolVersion" => version}),
    do: {:error, {:unsupported_protocol_version, version}}

  def negotiate_version(result) when is_map(result), do: {:ok, @protocol_version}

  @doc """
  Pick the revision OSA's own MCP SERVER will answer an `initialize` with.

  Per the lifecycle spec: if the client's requested version is supported the
  server MUST respond with that same version; otherwise it MUST respond with a
  version it does support (SHOULD be the latest). A client that cannot live
  with the answer disconnects.
  """
  @spec negotiate_server_version(term()) :: String.t()
  def negotiate_server_version(requested) when is_binary(requested) do
    if supports_version?(requested), do: requested, else: @protocol_version
  end

  def negotiate_server_version(_), do: @protocol_version

  @doc """
  Validate an inbound `MCP-Protocol-Version` header value (OSA as HTTP server).

  Returns `{:ok, version}` for a revision OSA supports, or
  `{:error, {:unsupported_protocol_version, value}}`, which the HTTP layer MUST
  turn into a `400 Bad Request` — the spec is explicit that an invalid or
  unsupported value is a 400, not a silent downgrade.

  A MISSING header is not an error: for backwards compatibility the spec says a
  server with no other way to identify the version SHOULD assume
  `#{@assumed_header_version}`, so `nil` resolves to that rather than rejecting.
  """
  @spec validate_protocol_version_header(term()) ::
          {:ok, String.t()} | {:error, {:unsupported_protocol_version, term()}}
  def validate_protocol_version_header(nil), do: {:ok, @assumed_header_version}
  def validate_protocol_version_header(""), do: {:ok, @assumed_header_version}

  def validate_protocol_version_header(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, @assumed_header_version}
      supports_version?(trimmed) -> {:ok, trimmed}
      true -> {:error, {:unsupported_protocol_version, value}}
    end
  end

  def validate_protocol_version_header(value),
    do: {:error, {:unsupported_protocol_version, value}}

  @client_info %{
    "name" => "osa",
    "version" => "1.0.0"
  }

  @doc """
  Build the `initialize` request (client → server handshake).

  `capabilities` lists ONLY what OSA implements — `roots`, answered by
  `MCP.Client.ServerSession`. `sampling` and `elicitation` are absent by design:
  announcing either would have servers issue requests OSA never answers, which
  hangs the server rather than degrading it.
  """
  @spec initialize(integer() | nil) :: map()
  def initialize(id \\ nil) do
    JSONRPC.request(
      "initialize",
      %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{
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
          cond do
            text != "" ->
              text

            # 2025-06-18 structured tool output. A server returning
            # `structuredContent` SHOULD also mirror it into a text block for
            # older clients, but that is a SHOULD — when it doesn't, the JSON
            # is the entire result, and dropping it (as the old code did, via
            # the "N content block(s)" placeholder) throws the answer away.
            true ->
              case structured_text(result) do
                nil when blocks != [] -> "[MCP result: #{length(blocks)} content block(s)]"
                nil -> ""
                json -> json
              end
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

  # 2025-03-26 content type. Binary audio is useless inline, so it is named
  # rather than dumped — but it must be NAMED: falling through to "" made a
  # lone audio result indistinguishable from an empty one.
  defp block_to_text(%{"type" => "audio"} = audio) do
    "[audio: #{audio["mimeType"] || "audio"}]"
  end

  # 2025-06-18 resource links. Unlike an embedded `resource` block these carry
  # no contents — only a pointer the agent can follow with a later tool call —
  # so the URI is the entire payload and must survive.
  defp block_to_text(%{"type" => "resource_link"} = link) do
    uri = link["uri"]

    cond do
      not is_binary(uri) or uri == "" ->
        ""

      is_binary(link["name"]) and link["name"] != "" ->
        "[resource_link: #{link["name"]} <#{uri}>]"

      true ->
        "[resource_link: #{uri}]"
    end
  end

  defp block_to_text(_), do: ""

  # Serialize a 2025-06-18 `structuredContent` payload for the text channel.
  # `nil` when absent or unencodable, so the caller can fall back.
  defp structured_text(%{"structuredContent" => structured}) when is_map(structured) do
    case Jason.encode(structured) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  defp structured_text(_), do: nil

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
