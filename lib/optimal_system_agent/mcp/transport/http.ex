defmodule OptimalSystemAgent.MCP.Transport.Http do
  @moduledoc """
  Remote MCP transport with StreamableHTTP → legacy-SSE fallback.

  Modern MCP servers speak **StreamableHTTP** (protocol `2025-03-26`): the
  client `POST`s each JSON-RPC message to a single endpoint and the reply comes
  back either as a lone `application/json` body or as a short `text/event-stream`
  the server closes once the response is delivered. Older servers speak the
  **HTTP+SSE** transport (`2024-11-05`): the client opens a long-lived `GET`
  SSE stream, whose first `endpoint` event names a separate URL to `POST`
  messages to; server→client messages then arrive as `message` events on the
  stream.

  Mirroring opencode (which tries `StreamableHTTPClientTransport`, then
  `SSEClientTransport`), this transport probes StreamableHTTP first and falls
  back to legacy SSE when the endpoint clearly rejects it (`404/405/406/415`).
  The fallback decision is the pure, unit-tested `classify_probe/1`.

  Network I/O runs in short-lived Tasks so the GenServer never blocks; results
  are delivered to the owner as the standard `{:mcp_message, ref, binary}` /
  `{:mcp_closed, ref, reason}` transport messages. SSE framing is delegated to
  the pure `OptimalSystemAgent.MCP.Transport.SSE` parser. Reconnect throttling
  (rapid-death backoff) lives in the owning `ServerSession` via
  `OptimalSystemAgent.MCP.Transport.SSEBackoff`, so this module stays a dumb pipe.

  Implements `OptimalSystemAgent.MCP.Transport`.
  """

  @behaviour OptimalSystemAgent.MCP.Transport

  use GenServer
  require Logger

  alias OptimalSystemAgent.MCP.Transport.SSE

  @accept "application/json, text/event-stream"
  @default_receive_timeout 60_000

  # StreamableHTTP endpoint statuses that mean "this server doesn't speak
  # StreamableHTTP" → fall back to legacy HTTP+SSE.
  @fallback_statuses [404, 405, 406, 415]

  defstruct [
    :owner,
    :ref,
    :name,
    :url,
    :headers,
    mode: :streamable_http,
    session_id: nil,
    post_url: nil,
    sse_buffer: "",
    sse_task: nil,
    probed?: false
  ]

  # ── Transport API ─────────────────────────────────────────────────────

  @impl OptimalSystemAgent.MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl OptimalSystemAgent.MCP.Transport
  def send_message(transport, message) when is_binary(message) do
    GenServer.call(transport, {:send, message})
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  # ── Pure fallback decision (unit-tested) ──────────────────────────────

  @doc """
  Classify a StreamableHTTP probe by its HTTP status.

    * `:ok`            — StreamableHTTP accepted (2xx); keep using it.
    * `:fallback_sse`  — endpoint rejects StreamableHTTP (404/405/406/415);
                         retry over the legacy HTTP+SSE transport.
    * `{:error, code}` — any other non-success status; surface as a failure.
  """
  @spec classify_probe(non_neg_integer()) :: :ok | :fallback_sse | {:error, non_neg_integer()}
  def classify_probe(status) when status in 200..299, do: :ok
  def classify_probe(status) when status in @fallback_statuses, do: :fallback_sse
  def classify_probe(status) when is_integer(status), do: {:error, status}

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      owner: Keyword.fetch!(opts, :owner),
      ref: Keyword.fetch!(opts, :ref),
      name: Keyword.get(opts, :name, "http"),
      url: Keyword.fetch!(opts, :url),
      headers: normalize_headers(Keyword.get(opts, :headers, %{}))
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    # Queue the send asynchronously so the caller (ServerSession) isn't blocked
    # on the round trip; the reply arrives later as {:mcp_message, ...}.
    send(self(), {:do_send, message})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:do_send, message}, %{mode: :streamable_http} = state) do
    {:noreply, post_streamable(message, state)}
  end

  def handle_info({:do_send, message}, %{mode: :sse} = state) do
    {:noreply, post_legacy(message, state)}
  end

  # Result of a StreamableHTTP POST: {status, headers, body}.
  def handle_info({:http_result, status, resp_headers, body}, state) do
    {:noreply, handle_streamable_response(status, resp_headers, body, state)}
  end

  def handle_info({:http_error, reason}, state) do
    Logger.warning("[MCP.Http:#{state.name}] request failed: #{inspect(reason)}")
    notify_closed(state, {:http_error, reason})
    {:stop, :normal, state}
  end

  # A chunk of the legacy SSE GET stream.
  def handle_info({:sse_chunk, chunk}, state) do
    {events, buffer} = SSE.parse(state.sse_buffer <> chunk)
    state = %{state | sse_buffer: buffer}
    Enum.each(events, &handle_sse_event(&1, state))
    {:noreply, state}
  end

  def handle_info({:sse_closed, reason}, state) do
    notify_closed(state, {:sse_closed, reason})
    {:stop, :normal, state}
  end

  def handle_info({:set_post_url, url}, state) do
    Logger.debug("[MCP.Http:#{state.name}] legacy SSE endpoint: #{url}")
    {:noreply, %{state | post_url: url}}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{sse_task: %Task{pid: pid}}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── StreamableHTTP ────────────────────────────────────────────────────

  defp post_streamable(message, state) do
    parent = self()
    url = state.url
    headers = streamable_headers(state)

    Task.start(fn ->
      case do_post(url, headers, message) do
        {:ok, status, resp_headers, body} ->
          send(parent, {:http_result, status, resp_headers, body})

        {:error, reason} ->
          send(parent, {:http_error, reason})
      end
    end)

    state
  end

  defp handle_streamable_response(status, resp_headers, body, state) do
    state = capture_session_id(resp_headers, state)

    # A 404 means two completely different things depending on whether we are
    # carrying a session id, and conflating them is a real misbehaviour:
    #
    #   * WITHOUT a session id it is "this endpoint does not speak
    #     StreamableHTTP", which is the legacy-SSE probe below.
    #   * WITH one it is the spec's session-expiry signal. The transport
    #     section is explicit: "When a client receives HTTP 404 in response to
    #     a request containing an Mcp-Session-Id, it MUST start a new session
    #     by sending a new InitializeRequest without a session id attached."
    #
    # Treating the second as the first downgrades a healthy modern server to a
    # DEPRECATED transport the moment its session times out — so a long-lived
    # OSA session silently loses StreamableHTTP after an idle period.
    if status == 404 and is_binary(state.session_id) do
      Logger.info(
        "[MCP.Http:#{state.name}] session expired (404 with Mcp-Session-Id); re-initializing"
      )

      notify_session_expired(%{state | session_id: nil})
    else
      dispatch_streamable(status, resp_headers, body, state)
    end
  end

  # The server terminated our session. Drop the id so the next request is a
  # fresh InitializeRequest, and tell the client to re-handshake. `probed?`
  # deliberately stays true: the endpoint has already proven it speaks
  # StreamableHTTP, so a later 404 must not be mistaken for a protocol probe.
  defp notify_session_expired(state) do
    notify_closed(state, :session_expired)
    state
  end

  defp dispatch_streamable(status, resp_headers, body, state) do
    case classify_probe(status) do
      :ok ->
        deliver_body(body, resp_headers, state)
        %{state | probed?: true}

      :fallback_sse when not state.probed? ->
        Logger.info(
          "[MCP.Http:#{state.name}] StreamableHTTP rejected (#{status}); falling back to SSE"
        )

        start_legacy_sse(%{state | mode: :sse, probed?: true})

      :fallback_sse ->
        notify_closed(state, {:http_status, status})
        state

      {:error, code} ->
        Logger.warning("[MCP.Http:#{state.name}] HTTP #{code} from server")
        notify_closed(state, {:http_status, code})
        state
    end
  end

  # A 202/empty body carries no message; otherwise deliver JSON directly or
  # parse an SSE body into its constituent messages.
  defp deliver_body("", _headers, _state), do: :ok
  defp deliver_body(nil, _headers, _state), do: :ok

  defp deliver_body(body, headers, state) do
    if sse?(headers) do
      {events, _rest} = SSE.parse(body)
      Enum.each(events, &handle_sse_event(&1, state))
    else
      deliver_json(body, state)
    end
  end

  # ── Legacy HTTP+SSE ───────────────────────────────────────────────────

  # Open the long-lived GET SSE stream. Chunks arrive as {:sse_chunk, _}.
  defp start_legacy_sse(state) do
    parent = self()
    url = state.url
    headers = sse_get_headers(state)

    task =
      Task.async(fn ->
        stream_sse(url, headers, parent)
      end)

    %{state | sse_task: task}
  end

  # POST a message in legacy mode — needs the endpoint URL learned from the
  # stream's `endpoint` event. If it hasn't arrived yet, drop (the handshake
  # retries); a real client could queue, but ServerSession's reconnect covers it.
  defp post_legacy(_message, %{post_url: nil} = state) do
    Logger.debug("[MCP.Http:#{state.name}] legacy SSE endpoint not yet known; deferring send")
    state
  end

  defp post_legacy(message, %{post_url: post_url} = state) do
    parent = self()
    headers = streamable_headers(state)

    Task.start(fn ->
      case do_post(post_url, headers, message) do
        {:ok, _status, _h, _body} -> :ok
        {:error, reason} -> send(parent, {:http_error, reason})
      end
    end)

    state
  end

  # Handle one SSE event. The `endpoint` event (legacy handshake) sets the POST
  # URL; every `message` event carries a JSON-RPC payload for the owner.
  defp handle_sse_event(%{type: "endpoint", data: data}, state) do
    # ServerSession holds this GenServer's state; we can't mutate it from a
    # helper called for side effects, so route through a message to self.
    send(self(), {:set_post_url, resolve_endpoint(state.url, data)})
    :ok
  end

  defp handle_sse_event(%{type: type, data: data}, state)
       when type in ["message", "message\n"] do
    deliver_json(data, state)
  end

  defp handle_sse_event(%{data: data}, state) do
    # Some servers omit the event type; treat any data as a message.
    deliver_json(data, state)
  end

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  # ── Shared HTTP helpers ───────────────────────────────────────────────

  defp do_post(url, headers, body) do
    case Req.post(url,
           headers: headers,
           body: body,
           decode_body: false,
           receive_timeout: @default_receive_timeout,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # Stream a GET SSE response, forwarding chunks to `parent` as {:sse_chunk, _}.
  # `Req`'s `:into` fun is invoked in this task for each body chunk.
  defp stream_sse(url, headers, parent) do
    result =
      Req.get(url,
        headers: headers,
        receive_timeout: :infinity,
        retry: false,
        into: fn {:data, chunk}, acc ->
          send(parent, {:sse_chunk, chunk})
          {:cont, acc}
        end
      )

    case result do
      {:ok, _resp} -> send(parent, {:sse_closed, :eof})
      {:error, reason} -> send(parent, {:sse_closed, reason})
    end
  rescue
    e -> send(parent, {:sse_closed, e})
  end

  defp deliver_json(json, state) do
    trimmed = String.trim(json)

    if trimmed != "" and (String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")) do
      send(state.owner, {:mcp_message, state.ref, trimmed})
    end

    :ok
  end

  defp notify_closed(%{owner: owner, ref: ref}, reason) do
    send(owner, {:mcp_closed, ref, reason})
  end

  # Base headers plus the negotiated session id (StreamableHTTP) if present.
  #
  # `MCP-Protocol-Version` is required by the transport spec on every HTTP
  # request after initialization, and OSA was not sending it. The consequence
  # is not a hard failure, which is why it went unnoticed: the spec tells a
  # server that receives no version header to ASSUME `2025-03-26`. So OSA was
  # being silently version-negotiated by omission — every server guessing,
  # none of them told.
  defp streamable_headers(state) do
    base =
      [
        {"content-type", "application/json"},
        {"accept", @accept},
        {"mcp-protocol-version", OptimalSystemAgent.MCP.Protocol.Messages.protocol_version()}
      ] ++ state.headers

    if state.session_id, do: [{"mcp-session-id", state.session_id} | base], else: base
  end

  defp sse_get_headers(state) do
    [{"accept", "text/event-stream"}] ++ state.headers
  end

  defp capture_session_id(resp_headers, state) do
    case header_value(resp_headers, "mcp-session-id") do
      nil -> state
      id -> %{state | session_id: id}
    end
  end

  defp sse?(headers) do
    case header_value(headers, "content-type") do
      nil -> false
      ct -> String.contains?(String.downcase(ct), "text/event-stream")
    end
  end

  # Req normalizes response headers to a map of name => [values]; be tolerant of
  # both the map and legacy list-of-tuples shapes.
  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    target = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == target, do: to_string(v)
    end)
  end

  defp header_value(_, _), do: nil

  defp normalize_headers(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(_), do: []

  # Resolve the legacy `endpoint` event's URL against the stream's base URL:
  # absolute URLs are used verbatim, a path is joined onto the origin.
  @doc false
  @spec resolve_endpoint(String.t(), String.t()) :: String.t()
  def resolve_endpoint(base_url, endpoint) do
    endpoint = String.trim(endpoint)

    cond do
      String.starts_with?(endpoint, "http://") or String.starts_with?(endpoint, "https://") ->
        endpoint

      String.starts_with?(endpoint, "/") ->
        uri = URI.parse(base_url)
        %{uri | path: endpoint, query: nil} |> URI.to_string()

      true ->
        endpoint
    end
  end
end
