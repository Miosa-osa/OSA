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
  backoff.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.Protocol.{JSONRPC, Messages}
  alias OptimalSystemAgent.MCP.Transport.Stdio

  @registry OptimalSystemAgent.MCP.Registry

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000
  @default_call_timeout 60_000
  # A stdio server whose transport opens but never replies to `initialize`
  # would otherwise sit in :connecting forever. Bound the handshake.
  @handshake_timeout_ms 30_000

  defstruct [
    :server,
    :transport_mod,
    :transport,
    :ref,
    status: :connecting,
    tools: [],
    pending: %{},
    init_id: nil,
    list_id: nil,
    backoff: @initial_backoff_ms
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

  @doc "Current lifecycle status: `:connecting | :ready | :failed`."
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
    state = %__MODULE__{server: server, transport_mod: transport_mod(server)}
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
        msg = Messages.call_tool(tool, arguments)
        id = msg["id"]

        case send_msg(state, msg) do
          :ok ->
            timer = Process.send_after(self(), {:call_timeout, id}, timeout)
            pending = Map.put(state.pending, id, {from, timer})
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
    Logger.warning("[MCP:#{state.server.name}] transport closed: #{inspect(reason)}")
    {:noreply, schedule_reconnect(fail_pending(state, :connection_closed))}
  end

  def handle_info(:reconnect, state) do
    {:noreply, connect(state)}
  end

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:handshake_timeout, id}, %{init_id: id} = state) when not is_nil(id) do
    # initialize is still pending after the deadline — the server started but
    # never completed the handshake. Mark failed and retry with backoff.
    Logger.warning(
      "[MCP:#{state.server.name}] initialize timed out after #{@handshake_timeout_ms}ms — retrying"
    )

    {:noreply, schedule_reconnect(%{state | status: :failed})}
  end

  def handle_info({:handshake_timeout, _id}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Connection ────────────────────────────────────────────────────────

  defp connect(%{server: %Server{transport: :http_sse}} = state) do
    # Phase 1 supports stdio only; HTTP/SSE is a Phase 2 transport.
    Logger.info("[MCP:#{state.server.name}] http_sse transport not yet supported; skipping")
    %{state | status: :failed}
  end

  defp connect(%{server: server} = state) do
    ref = make_ref()

    opts = [
      owner: self(),
      ref: ref,
      name: server.name,
      command: server.command,
      args: server.args,
      env: server.env
    ]

    case state.transport_mod.start_link(opts) do
      {:ok, transport} ->
        Logger.info("[MCP:#{server.name}] transport started, initializing")
        state = %{state | transport: transport, ref: ref, status: :connecting}
        start_handshake(state)

      {:error, reason} ->
        Logger.warning("[MCP:#{server.name}] transport failed to start: #{inspect(reason)}")
        schedule_reconnect(%{state | transport: nil, status: :failed})
    end
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
        Logger.warning("[MCP:#{state.server.name}] initialize send failed: #{inspect(reason)}")
        schedule_reconnect(%{state | status: :failed})
    end
  end

  # ── Inbound handling ──────────────────────────────────────────────────

  defp handle_inbound(bin, state) do
    case JSONRPC.decode(bin) do
      {:ok, {:response, id, result}} -> handle_response(id, result, state)
      {:ok, {:error, id, err}} -> handle_error(id, err, state)
      {:ok, {:notification, _method, _params}} -> state
      {:ok, {:request, _id, _method, _params}} -> state
      {:error, reason} ->
        Logger.debug("[MCP:#{state.server.name}] decode failed: #{inspect(reason)}")
        state
    end
  end

  defp handle_response(id, _result, %{init_id: id} = state) do
    # initialize succeeded → send `initialized`, then request the tool list.
    _ = send_msg(state, Messages.initialized())
    list = Messages.list_tools()

    case send_msg(state, list) do
      :ok ->
        %{state | status: :ready, init_id: nil, list_id: list["id"], backoff: @initial_backoff_ms}

      {:error, _reason} ->
        %{state | status: :ready, init_id: nil, backoff: @initial_backoff_ms}
    end
  end

  defp handle_response(id, result, %{list_id: id} = state) do
    tools = Messages.parse_tool_list(result)
    Logger.info("[MCP:#{state.server.name}] discovered #{length(tools)} tools")
    report_tools(state.server.name, tools)
    %{state | tools: tools, list_id: nil}
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, result})
        %{state | pending: pending}
    end
  end

  defp handle_error(id, err, %{init_id: id} = state) do
    Logger.warning("[MCP:#{state.server.name}] initialize error: #{inspect(err)}")
    schedule_reconnect(%{state | status: :failed, init_id: nil})
  end

  defp handle_error(id, err, %{list_id: id} = state) do
    Logger.warning("[MCP:#{state.server.name}] tools/list error: #{inspect(err)}")
    %{state | list_id: nil}
  end

  defp handle_error(id, err, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, {:error, {:mcp_error, err}})
        %{state | pending: pending}
    end
  end

  # ── Reconnect / cleanup ───────────────────────────────────────────────

  defp schedule_reconnect(state) do
    backoff = state.backoff
    Process.send_after(self(), :reconnect, backoff)
    next = min(backoff * 2, @max_backoff_ms)
    %{state | transport: nil, ref: nil, backoff: next}
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer}} ->
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

  defp transport_mod(%Server{transport: :stdio}) do
    Application.get_env(:optimal_system_agent, :mcp_stdio_transport, Stdio)
  end

  defp transport_mod(_) do
    Application.get_env(:optimal_system_agent, :mcp_stdio_transport, Stdio)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
