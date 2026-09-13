defmodule OptimalSystemAgent.MCP.Client.ServerSession do
  @moduledoc """
  One GenServer per configured MCP server.

  Runs under `OptimalSystemAgent.MCP.Supervisor` and is registered by server
  name in `OptimalSystemAgent.MCP.Registry` via `{:via, Registry, ...}`.

  Lifecycle (never blocks the caller/boot on a slow server):

      connect → initialize → notifications/initialized → tools/list

  The handshake runs asynchronously as inbound transport messages arrive; the
  discovered tool schemas are reported to `MCP.Client.Manager` when ready.
  `call_tool/3` correlates a JSON-RPC id to the blocked caller and replies via
  `GenServer.reply/2` when the matching response arrives (or on timeout).

  On transport close, the session schedules a reconnect with exponential
  backoff — but only up to a bounded number of consecutive connect failures
  (`@max_connect_failures`). Once that cap is reached the session goes
  `:dormant` and STOPS reconnecting, so a permanently-broken server (a package
  that 404s, a missing key) can no longer spin an unbounded npx-spawn loop that
  blows the MCP supervisor's restart budget and cascades to the app root. A
  connection that survives the stability window resets the counter, so a
  flapping-but-recovering server is never penalized. This bounded auto-connect
  is what makes discovery's auto-load (Discovery.discover/0) safe to enable.

  The session also traps exits: the transport is LINKED, so a transport crash
  would otherwise take the session down and have the DynamicSupervisor restart
  it fresh — resetting the failure counter and defeating the cap. Trapping lets
  a transport crash route through the capped reconnect path instead.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.Protocol.{JSONRPC, Messages}
  alias OptimalSystemAgent.MCP.Transport.{Http, SSEBackoff, Stdio}

  @registry OptimalSystemAgent.MCP.Registry

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000
  @default_call_timeout 60_000
  # A stdio server whose transport opens but never replies to `initialize`
  # would otherwise sit in :connecting forever. Bound the handshake.
  @handshake_timeout_ms 30_000
  # A connection must survive this long after a completed handshake before it
  # counts as "stable" and resets the reconnect backoff. A stream that dies
  # sooner is a rapid death and keeps the backoff escalating (grok's SSE
  # 2s `STABLE_STREAM_THRESHOLD`). Prevents a flapping server from hot-looping.
  @stable_after_ms 2_000
  # Guard against a server that paginates its tool list forever (or loops on a
  # repeated cursor); bound total pages defensively.
  @max_list_pages 1_000
  # Bounded auto-connect: after this many CONSECUTIVE connect failures (transport
  # never starts, handshake never completes, or the stream dies before it is
  # stable) the session goes `:dormant` and stops reconnecting. A broken server
  # thus makes a small, bounded burst of attempts then goes quiet instead of
  # hot-looping forever. A stable connection (see `:mark_stable`) resets the
  # count. Overridable in tests via `:mcp_max_connect_failures`.
  @max_connect_failures 5

  defstruct [
    :server,
    :transport_mod,
    :transport,
    :ref,
    :throttle,
    status: :connecting,
    tools: [],
    pending: %{},
    init_id: nil,
    list_id: nil,
    # Pagination accumulator for a multi-page tools/list.
    tools_acc: [],
    list_cursors: nil,
    list_pages: 0,
    # Reconnect-stability tracking. `stable_ref` is the timer that, once fired,
    # marks the current connection healthy; `conn_gen` invalidates stale timers.
    stable_ref: nil,
    conn_gen: 0,
    stable?: false,
    # Consecutive connect-failure counter for the dormancy cap. Reset to 0 when a
    # connection survives the stability window (`:mark_stable`).
    fail_count: 0,
    backoff: @initial_backoff_ms,
    # The MCP revision this connection settled on. `nil` until `initialize`
    # returns; the server MAY answer with a revision older than the one OSA
    # announced, and everything after the handshake — including the
    # `MCP-Protocol-Version` header — must follow the answer, not the request.
    protocol_version: nil
  ]

  # ── Public API ────────────────────────────────────────────────────────

  @doc "Child spec / start under the MCP DynamicSupervisor."
  def start_link(%Server{} = server) do
    GenServer.start_link(__MODULE__, server, name: via(server.name))
  end

  def child_spec(%Server{} = server) do
    %{
      id: {__MODULE__, server.name},
      start: {__MODULE__, :start_link, [server]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Registry `:via` tuple for a server name."
  def via(name), do: {:via, Registry, {@registry, name}}

  @doc "Whether a session for `name` is currently registered."
  def alive?(name) do
    case Registry.lookup(@registry, name) do
      [{_pid, _}] -> true
      _ -> false
    end
  end

  @doc "Return the discovered tool schemas (raw MCP maps). Empty until ready."
  def list_tools(name) do
    GenServer.call(via(name), :list_tools)
  catch
    :exit, _ -> []
  end

  @doc "Current lifecycle status: `:connecting | :ready | :failed | :dormant`."
  def status(name) do
    GenServer.call(via(name), :status)
  catch
    :exit, _ -> :down
  end

  @doc """
  Call a tool on this server. Blocks the caller up to `timeout` while the
  request is correlated to its JSON-RPC response.
  """
  @spec call_tool(String.t(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(name, tool, arguments, timeout \\ @default_call_timeout) do
    GenServer.call(via(name), {:call_tool, tool, arguments, timeout}, timeout + 5_000)
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(%Server{} = server) do
    # Trap exits so a crash of the LINKED transport becomes an `{:EXIT, ...}`
    # message we route through the capped reconnect path, instead of taking this
    # session down and letting the DynamicSupervisor restart it fresh (which
    # would reset the failure counter and defeat the dormancy cap).
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      server: server,
      transport_mod: transport_mod(server),
      throttle: SSEBackoff.new(base_ms: initial_backoff_ms(), max_ms: max_backoff_ms()),
      list_cursors: MapSet.new()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  @impl true
  def handle_call(:list_tools, _from, state), do: {:reply, state.tools, state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:call_tool, tool, arguments, timeout}, from, state) do
    cond do
      state.status != :ready ->
        {:reply, {:error, :not_ready}, state}

      is_nil(state.transport) ->
        {:reply, {:error, :no_transport}, state}

      true ->
        # Attach a progressToken (the request id) so the server MAY emit
        # `notifications/progress` for a long-running call; each such
        # notification RESETS this call's timeout, so a tool that keeps
        # reporting progress never trips the request timeout (opencode's
        # `resetTimeoutOnProgress`).
        msg = Messages.call_tool(tool, arguments, nil, nil)
        id = msg["id"]
        msg = put_progress_token(msg, id)

        case send_msg(state, msg) do
          :ok ->
            timer = Process.send_after(self(), {:call_timeout, id}, timeout)
            # Store the timeout so a progress notification can re-arm the timer.
            pending = Map.put(state.pending, id, {from, timer, timeout})
            {:noreply, %{state | pending: pending}}

          {:error, reason} ->
            {:reply, {:error, {:send_failed, reason}}, state}
        end
    end
  end

  @impl true
  def handle_info({:mcp_message, ref, bin}, %{ref: ref} = state) do
    {:noreply, handle_inbound(bin, state)}
  end

  def handle_info({:mcp_closed, ref, reason}, %{ref: ref} = state) do
    # Expected for optional/misconfigured servers on a fresh install; not
    # individually actionable, so keep it at debug and let the Manager emit a
    # single calm boot summary instead of a per-server wall of warnings.
    Logger.debug("[MCP:#{state.server.name}] transport closed: #{inspect(reason)}")
    {:noreply, schedule_reconnect(fail_pending(state, :connection_closed))}
  end

  def handle_info(:reconnect, state) do
    {:noreply, connect(state)}
  end

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer, _timeout}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  # A stability timer fired: if it belongs to the CURRENT connection generation
  # and the connection is still up, the stream has survived the stability window
  # — mark it healthy and reset the reconnect backoff.
  def handle_info({:mark_stable, gen}, %{conn_gen: gen, status: :ready} = state) do
    # A survived connection also clears the dormancy failure counter, so a server
    # that flapped a few times but then recovered is not held against the cap.
    {:noreply,
     %{state | stable?: true, fail_count: 0, throttle: SSEBackoff.mark_stable(state.throttle)}}
  end

  def handle_info({:mark_stable, _gen}, state), do: {:noreply, state}

  def handle_info({:handshake_timeout, id}, %{init_id: id} = state) when not is_nil(id) do
    # initialize is still pending after the deadline — the server started but
    # never completed the handshake. Mark failed and retry with backoff. Expected
    # for a misconfigured/optional server; debug, not warning (see boot summary).
    Logger.debug(
      "[MCP:#{state.server.name}] initialize timed out after #{@handshake_timeout_ms}ms — retrying"
    )

    {:noreply, schedule_reconnect(%{state | status: :failed})}
  end

  def handle_info({:handshake_timeout, _id}, state), do: {:noreply, state}

  # The LINKED transport exited normally / was shut down: this is a real
  # teardown (e.g. the transport was deliberately stopped), so stop the session
  # cleanly rather than reconnecting. Normal supervisor shutdown of the session
  # itself arrives as a parent EXIT that `:gen_server` handles directly, so this
  # clause never turns a routine shutdown into a reconnect.
  def handle_info({:EXIT, pid, reason}, %{transport: pid} = state)
      when is_pid(pid) and reason in [:normal, :shutdown] do
    {:stop, reason, state}
  end

  # The LINKED transport CRASHED (abnormal exit). Because we trap exits this
  # arrives as a message instead of killing us; route it through the capped
  # reconnect path so a flapping transport counts toward dormancy instead of
  # having the supervisor restart us fresh. Note: a clean `{:mcp_closed, ...}`
  # already nils `state.transport` before this fires, so a transport that closed
  # then exited :normal falls through to the ignore clause below (no double-count).
  def handle_info({:EXIT, pid, reason}, %{transport: pid} = state) when is_pid(pid) do
    # Expected connectivity failure for an optional/misconfigured server; debug.
    Logger.debug("[MCP:#{state.server.name}] transport crashed: #{inspect(reason)}")
    {:noreply, schedule_reconnect(fail_pending(state, :transport_crashed))}
  end

  # An EXIT from anything that is not our current transport (a stale transport
  # already replaced, a transient helper port, etc.) is ignored.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Connection ────────────────────────────────────────────────────────

  defp connect(%{server: server} = state) do
    ref = make_ref()
    # New connection generation invalidates any stale stability timer and marks
    # the connection not-yet-stable until it survives the stability window.
    state = %{state | conn_gen: state.conn_gen + 1, stable?: false, stable_ref: nil}
    mod = transport_mod(server)
    opts = transport_opts(server, ref)

    case mod.start_link(opts) do
      {:ok, transport} ->
        # Per-server boot chatter: keep at debug so a 16-server fresh install
        # does not print 16 "transport started" lines. The Manager boot summary
        # is the one line a newcomer sees.
        Logger.debug("[MCP:#{server.name}] #{server.transport} transport started, initializing")
        state = %{state | transport_mod: mod, transport: transport, ref: ref, status: :connecting}
        start_handshake(state)

      {:error, reason} ->
        # Expected for an optional server whose package/command is unavailable.
        Logger.debug("[MCP:#{server.name}] transport failed to start: #{inspect(reason)}")
        schedule_reconnect(%{state | transport: nil, status: :failed})
    end
  end

  # Build transport-specific start options. Stdio needs the subprocess spec;
  # HTTP/SSE needs the URL + headers.
  defp transport_opts(%Server{transport: :http_sse} = server, ref) do
    [
      owner: self(),
      ref: ref,
      name: server.name,
      url: server.url,
      headers: server.headers
    ]
  end

  defp transport_opts(%Server{} = server, ref) do
    [
      owner: self(),
      ref: ref,
      name: server.name,
      command: server.command,
      args: server.args,
      env: server.env
    ]
  end

  defp start_handshake(state) do
    msg = Messages.initialize()

    case send_msg(state, msg) do
      :ok ->
        # Arm a handshake deadline so a server that never replies to initialize
        # is retried with backoff instead of being silently stuck :connecting.
        Process.send_after(self(), {:handshake_timeout, msg["id"]}, @handshake_timeout_ms)
        %{state | init_id: msg["id"]}

      {:error, reason} ->
        # Expected connectivity failure for an optional/misconfigured server; debug.
        Logger.debug("[MCP:#{state.server.name}] initialize send failed: #{inspect(reason)}")
        schedule_reconnect(%{state | status: :failed})
    end
  end

  # ── Inbound handling ──────────────────────────────────────────────────

  defp handle_inbound(bin, state) do
    case JSONRPC.decode(bin) do
      {:ok, {:response, id, result}} ->
        handle_response(id, result, state)

      {:ok, {:error, id, err}} ->
        handle_error(id, err, state)

      {:ok, {:notification, method, params}} ->
        handle_notification(method, params, state)

      {:ok, {:request, req_id, method, params}} ->
        handle_request(req_id, method, params, state)

      {:error, reason} ->
        Logger.debug("[MCP:#{state.server.name}] decode failed: #{inspect(reason)}")
        state
    end
  end

  # A progress notification for an in-flight tool call: re-arm that call's
  # timeout so a long-running tool that keeps reporting progress doesn't trip
  # the request timeout. The progressToken is the request id we attached.
  defp handle_notification("notifications/progress", %{"progressToken" => token}, state) do
    case Map.get(state.pending, token) do
      {from, timer, timeout} ->
        cancel_timer(timer)
        new_timer = Process.send_after(self(), {:call_timeout, token}, timeout)
        %{state | pending: Map.put(state.pending, token, {from, new_timer, timeout})}

      _ ->
        state
    end
  end

  defp handle_notification(_method, _params, state), do: state

  # ── Inbound server → client REQUESTS ──────────────────────────────────
  #
  # These were previously dropped on the floor. A JSON-RPC request that is never
  # answered is not a no-op: the server sits waiting on a reply that will never
  # come, and a server that blocks its own handshake on `roots/list` (a normal
  # thing to do, since OSA ANNOUNCES the roots capability) never becomes ready.
  # Every inbound request now gets a response — the real answer where OSA
  # implements the method, an explicit method-not-found where it does not.

  @method_not_found -32601

  # `roots/list` — the one client capability OSA announces. The workspace root
  # is the directory the agent is actually operating in.
  defp handle_request(id, "roots/list", _params, state) do
    _ = send_msg(state, JSONRPC.response(id, %{"roots" => roots()}))
    state
  end

  defp handle_request(id, "ping", _params, state) do
    _ = send_msg(state, JSONRPC.response(id, %{}))
    state
  end

  # Anything else — `sampling/createMessage`, `elicitation/create`, … OSA does
  # not announce those capabilities, so a conforming server should never ask;
  # answering with method-not-found tells a non-conforming one immediately
  # instead of leaving it hanging.
  defp handle_request(id, method, _params, state) do
    Logger.debug("[MCP:#{state.server.name}] unsupported inbound request #{inspect(method)}")

    _ =
      send_msg(
        state,
        JSONRPC.error_response(id, @method_not_found, "Method not found: #{method}")
      )

    state
  end

  defp roots do
    cwd = OptimalSystemAgent.Workspace.Cwd.get()

    [%{"uri" => "file://" <> cwd, "name" => Path.basename(cwd)}]
  rescue
    _ -> []
  end

  defp handle_response(id, result, %{init_id: id} = state) do
    case Messages.negotiate_version(result) do
      {:ok, version} -> complete_handshake(version, state)
      {:error, reason} -> reject_handshake(reason, state)
    end
  end

  defp handle_response(id, result, %{list_id: id} = state) do
    page_tools = Messages.parse_tool_list(result)
    acc = state.tools_acc ++ page_tools
    cursor = Messages.next_cursor(result)
    pages = state.list_pages + 1

    cond do
      # No more pages — finalize the aggregated tool list.
      is_nil(cursor) ->
        finalize_tools(acc, state)

      # Defensive bounds: a repeated cursor is a server paginating in a loop;
      # too many pages is a runaway. Stop and use what we have.
      MapSet.member?(state.list_cursors, cursor) ->
        Logger.warning(
          "[MCP:#{state.server.name}] tools/list returned duplicate cursor; stopping pagination"
        )

        finalize_tools(acc, state)

      pages >= @max_list_pages ->
        Logger.warning(
          "[MCP:#{state.server.name}] tools/list exceeded #{@max_list_pages} pages; stopping"
        )

        finalize_tools(acc, state)

      # Fetch the next page.
      true ->
        next = Messages.list_tools(nil, cursor)

        case send_msg(state, next) do
          :ok ->
            %{
              state
              | tools_acc: acc,
                list_id: next["id"],
                list_cursors: MapSet.put(state.list_cursors, cursor),
                list_pages: pages
            }

          {:error, _reason} ->
            # Can't fetch the next page — finalize with what we have.
            finalize_tools(acc, state)
        end
    end
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer, _timeout}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, result})
        %{state | pending: pending}
    end
  end

  # The server answered with a revision OSA cannot speak. Continuing would mean
  # exchanging messages under a schema neither side agreed on, so drop the
  # connection instead — the lifecycle spec says the client SHOULD disconnect.
  defp reject_handshake({:unsupported_protocol_version, version}, state) do
    Logger.warning(
      "[MCP:#{state.server.name}] server negotiated unsupported MCP revision " <>
        "#{inspect(version)} (OSA speaks #{Enum.join(Messages.supported_versions(), ", ")}); " <>
        "disconnecting"
    )

    schedule_reconnect(%{state | status: :failed, init_id: nil})
  end

  defp complete_handshake(version, state) do
    if version != Messages.protocol_version() do
      Logger.debug(
        "[MCP:#{state.server.name}] negotiated down to MCP #{version} " <>
          "(announced #{Messages.protocol_version()})"
      )
    end

    # Tell the HTTP transport which revision won, so the `MCP-Protocol-Version`
    # header on every subsequent request carries the NEGOTIATED value rather
    # than the one we opened with. Only the HTTP transport has headers, so the
    # message is not broadcast at transports that would have no use for it.
    if state.transport_mod == Http and is_pid(state.transport) do
      send(state.transport, {:mcp_protocol_version, version})
    end

    state = %{state | protocol_version: version}

    # initialize succeeded → send `initialized`, then request the first tool
    # page. Don't reset the backoff yet: the connection must survive the
    # stability window first (see `:mark_stable`), so a server that handshakes
    # then dies instantly still escalates its reconnect delay.
    _ = send_msg(state, Messages.initialized())
    list = Messages.list_tools(nil, nil)

    state =
      %{
        state
        | status: :ready,
          init_id: nil,
          tools_acc: [],
          list_cursors: MapSet.new(),
          list_pages: 0
      }
      |> arm_stability_timer()

    case send_msg(state, list) do
      :ok -> %{state | list_id: list["id"]}
      {:error, _reason} -> state
    end
  end

  defp handle_error(id, err, %{init_id: id} = state) do
    # Expected for a server that rejects the handshake (bad config/version); debug.
    Logger.debug("[MCP:#{state.server.name}] initialize error: #{inspect(err)}")
    schedule_reconnect(%{state | status: :failed, init_id: nil})
  end

  defp handle_error(id, err, %{list_id: id} = state) do
    # Expected connectivity/availability failure; debug (see boot summary).
    Logger.debug("[MCP:#{state.server.name}] tools/list error: #{inspect(err)}")
    # Finalize with whatever pages we accumulated before the error.
    finalize_tools(state.tools_acc, state)
  end

  defp handle_error(id, err, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer, _timeout}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, {:error, {:mcp_error, err}})
        %{state | pending: pending}
    end
  end

  # ── Reconnect / cleanup ───────────────────────────────────────────────

  # Rapid-death-aware reconnect backoff (grok's SSE throttle) WITH a dormancy cap.
  # A connection that reached the stability window (`stable?`) resets the failure
  # count to 1; otherwise the count escalates by one. Once it reaches
  # `max_connect_failures/0` the server is treated as permanently broken: mark it
  # `:dormant` and do NOT schedule another reconnect (no `:reconnect` message), so
  # it makes a bounded burst of attempts then goes quiet. Below the cap, a rapid
  # death (or a server that never connects) escalates the delay geometrically
  # toward the ceiling, exactly as before.
  defp schedule_reconnect(state) do
    fail_count = if state.stable?, do: 1, else: state.fail_count + 1

    if fail_count >= max_connect_failures() do
      # Expected end-state for a permanently-broken optional server on a fresh
      # install. Kept at debug so it does not read as a broken install; the count
      # of dormant servers is surfaced calmly in the Manager boot summary, and
      # `osa doctor` / `MCP list_servers` still show per-server dormant status.
      Logger.debug(
        "[MCP:#{state.server.name}] #{fail_count} consecutive connect failures — going dormant, " <>
          "stopping reconnects (enable it manually once its config is fixed)"
      )

      %{
        state
        | transport: nil,
          ref: nil,
          status: :dormant,
          fail_count: fail_count,
          stable?: false,
          stable_ref: nil
      }
    else
      {delay, throttle} = SSEBackoff.observe_death(state.throttle, state.stable?)
      Process.send_after(self(), :reconnect, delay)

      %{
        state
        | transport: nil,
          ref: nil,
          throttle: throttle,
          fail_count: fail_count,
          stable?: false,
          stable_ref: nil
      }
    end
  end

  # Arm a one-shot timer that, once elapsed, marks the CURRENT connection stable
  # (resetting the backoff). A close before it fires leaves the backoff escalated.
  defp arm_stability_timer(state) do
    ref = Process.send_after(self(), {:mark_stable, state.conn_gen}, @stable_after_ms)
    %{state | stable_ref: ref}
  end

  # Finalize a (possibly paginated) tools/list: publish the aggregated tools and
  # clear pagination state.
  defp finalize_tools(tools, state) do
    # Per-server success is boot chatter too; keep it at debug so the Manager's
    # single "connected N of M servers" summary is the one line a newcomer sees.
    Logger.debug("[MCP:#{state.server.name}] discovered #{length(tools)} tools")
    report_tools(state.server.name, tools)

    %{
      state
      | tools: tools,
        list_id: nil,
        tools_acc: [],
        list_cursors: MapSet.new(),
        list_pages: 0
    }
  end

  # Attach a `_meta.progressToken` to an outbound tools/call so the server may
  # emit progress notifications that reset the call timeout.
  defp put_progress_token(%{"params" => params} = msg, token) do
    meta = Map.get(params, "_meta", %{}) |> Map.put("progressToken", token)
    %{msg | "params" => Map.put(params, "_meta", meta)}
  end

  defp put_progress_token(msg, _token), do: msg

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer, _timeout}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp send_msg(%{transport_mod: mod, transport: transport}, msg) when is_pid(transport) do
    case JSONRPC.encode(msg) do
      {:ok, bin} -> mod.send_message(transport, bin)
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp send_msg(_state, _msg), do: {:error, :no_transport}

  defp report_tools(name, tools) do
    OptimalSystemAgent.MCP.Client.Manager.report_tools(name, tools)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp transport_mod(%Server{transport: :http_sse}) do
    Application.get_env(:optimal_system_agent, :mcp_http_transport, Http)
  end

  defp transport_mod(_) do
    Application.get_env(:optimal_system_agent, :mcp_stdio_transport, Stdio)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  # Tunables. Defaults are the module attributes; tests override them via
  # Application env to make the dormancy cap fast and deterministic.
  defp max_connect_failures do
    Application.get_env(:optimal_system_agent, :mcp_max_connect_failures, @max_connect_failures)
  end

  defp initial_backoff_ms do
    Application.get_env(:optimal_system_agent, :mcp_initial_backoff_ms, @initial_backoff_ms)
  end

  defp max_backoff_ms do
    Application.get_env(:optimal_system_agent, :mcp_max_backoff_ms, @max_backoff_ms)
  end
end
