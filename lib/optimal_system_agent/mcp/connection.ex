defmodule OptimalSystemAgent.MCP.Connection do
  @moduledoc """
  SSE connection manager for MCP servers.

  Manages the HTTP SSE streaming connection to an MCP server endpoint.
  Parses the SSE wire format (event/data/comment lines) and forwards
  parsed events to the owning MCP.Client process.

  Connection state machine: :disconnected -> :connecting -> :connected

  Reconnects with exponential backoff on disconnect (1s, 2s, 4s, ... max 30s).
  Monitors SSE heartbeat comments (`: heartbeat`) and triggers reconnect
  if no data arrives within the heartbeat timeout (45s default).
  """
  use GenServer

  require Logger

  alias OptimalSystemAgent.MCP.Connection

  @heartbeat_timeout_ms 45_000
  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000

  defstruct [
    :url,
    :api_key,
    :client_pid,
    :task_ref,
    :heartbeat_timer,
    state: :disconnected,
    backoff_ms: @initial_backoff_ms,
    buffer: ""
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "Returns the current connection state (:disconnected | :connecting | :connected)."
  @spec connection_state(GenServer.server()) :: :disconnected | :connecting | :connected
  def connection_state(server) do
    GenServer.call(server, :connection_state)
  end

  @doc "Initiate connection to the SSE endpoint."
  @spec connect(GenServer.server()) :: :ok
  def connect(server) do
    GenServer.cast(server, :connect)
  end

  @doc "Disconnect from the SSE endpoint."
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server) do
    GenServer.cast(server, :disconnect)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %Connection{
      url: Keyword.fetch!(opts, :url),
      api_key: Keyword.get(opts, :api_key),
      client_pid: Keyword.fetch!(opts, :client_pid)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connection_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_cast(:connect, %{state: :connecting} = state) do
    {:noreply, state}
  end

  def handle_cast(:connect, state) do
    {:noreply, start_connection(state)}
  end

  def handle_cast(:disconnect, state) do
    {:noreply, do_disconnect(state)}
  end

  @impl true
  def handle_info({:sse_chunk, chunk}, state) do
    {events, new_buffer} = parse_sse_buffer(state.buffer <> chunk)
    state = reset_heartbeat_timer(%{state | buffer: new_buffer})

    Enum.each(events, fn event ->
      send(state.client_pid, {:sse_event, event})
    end)

    {:noreply, state}
  end

  def handle_info({:sse_connected}, state) do
    Logger.info("[MCP.Connection] SSE connected to #{state.url}")

    state =
      state
      |> Map.put(:state, :connected)
      |> Map.put(:backoff_ms, @initial_backoff_ms)
      |> reset_heartbeat_timer()

    send(state.client_pid, {:connection_state, :connected})
    {:noreply, state}
  end

  def handle_info({:sse_error, reason}, state) do
    Logger.warning("[MCP.Connection] SSE error: #{inspect(reason)}")
    {:noreply, schedule_reconnect(do_disconnect(state))}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion message — ignore
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("[MCP.Connection] SSE stream task exited: #{inspect(reason)}")
    end

    {:noreply, schedule_reconnect(%{state | task_ref: nil, state: :disconnected})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("[MCP.Connection] Heartbeat timeout — reconnecting")
    {:noreply, schedule_reconnect(do_disconnect(state))}
  end

  def handle_info(:reconnect, state) do
    {:noreply, start_connection(state)}
  end

  # --- Private Functions ---

  defp start_connection(state) do
    state = do_disconnect(state)
    Logger.info("[MCP.Connection] Connecting to #{state.url}")

    parent = self()

    task =
      Task.async(fn ->
        stream_sse(state.url, state.api_key, parent)
      end)

    %{state | state: :connecting, task_ref: task.ref}
  end

  defp stream_sse(url, api_key, parent) do
    headers = build_headers(api_key)

    # Use Req with into: :self for streaming
    case Req.get(url, headers: headers, into: :self, receive_timeout: :infinity) do
      {:ok, resp} when resp.status == 200 ->
        send(parent, {:sse_connected})
        receive_sse_loop(parent)

      {:ok, resp} ->
        send(parent, {:sse_error, {:http_status, resp.status}})

      {:error, reason} ->
        send(parent, {:sse_error, reason})
    end
  end

  defp receive_sse_loop(parent) do
    receive do
      {_ref, {:data, chunk}} ->
        send(parent, {:sse_chunk, chunk})
        receive_sse_loop(parent)

      {_ref, :done} ->
        send(parent, {:sse_error, :stream_ended})

      {_ref, {:error, reason}} ->
        send(parent, {:sse_error, reason})
    after
      @heartbeat_timeout_ms ->
        send(parent, {:sse_error, :receive_timeout})
    end
  end

  defp build_headers(nil), do: [{"accept", "text/event-stream"}]

  defp build_headers(api_key) do
    [
      {"accept", "text/event-stream"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  defp do_disconnect(state) do
    if state.task_ref do
      # Demonitor and kill the streaming task
      Process.demonitor(state.task_ref, [:flush])

      case Process.info(self(), :links) do
        {:links, links} ->
          Enum.each(links, fn pid ->
            if is_pid(pid) and pid != self(), do: Process.exit(pid, :shutdown)
          end)

        _ ->
          :ok
      end
    end

    cancel_heartbeat_timer(state)
    send(state.client_pid, {:connection_state, :disconnected})
    %{state | state: :disconnected, task_ref: nil, buffer: "", heartbeat_timer: nil}
  end

  defp schedule_reconnect(state) do
    Logger.info("[MCP.Connection] Reconnecting in #{state.backoff_ms}ms")
    Process.send_after(self(), :reconnect, state.backoff_ms)
    new_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
    %{state | backoff_ms: new_backoff}
  end

  defp reset_heartbeat_timer(state) do
    state = cancel_heartbeat_timer(state)
    timer = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout_ms)
    %{state | heartbeat_timer: timer}
  end

  defp cancel_heartbeat_timer(%{heartbeat_timer: nil} = state), do: state

  defp cancel_heartbeat_timer(%{heartbeat_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | heartbeat_timer: nil}
  end

  @doc false
  def parse_sse_buffer(data) do
    # SSE format: lines separated by \n, blocks separated by \n\n
    # event: name\ndata: payload\n\n
    # Comments start with : (heartbeats)
    parts = String.split(data, "\n\n", trim: false)

    case parts do
      [incomplete] ->
        # No complete block yet
        {[], incomplete}

      blocks ->
        # Last element may be an incomplete block
        {complete_blocks, [remainder]} = Enum.split(blocks, -1)

        events =
          complete_blocks
          |> Enum.map(&parse_sse_block/1)
          |> Enum.reject(&is_nil/1)

        {events, remainder}
    end
  end

  defp parse_sse_block(block) do
    lines = String.split(block, "\n", trim: true)

    result =
      Enum.reduce(lines, %{}, fn line, acc ->
        cond do
          String.starts_with?(line, ": ") or line == ":" ->
            # SSE comment (heartbeat) — mark as seen
            Map.put(acc, :comment, String.trim_leading(line, ": "))

          String.starts_with?(line, "event: ") ->
            Map.put(acc, :event, String.trim_leading(line, "event: "))

          String.starts_with?(line, "data: ") ->
            data = String.trim_leading(line, "data: ")
            # Append to existing data (multi-line data fields)
            existing = Map.get(acc, :data, "")
            separator = if existing == "", do: "", else: "\n"
            Map.put(acc, :data, existing <> separator <> data)

          String.starts_with?(line, "id: ") ->
            Map.put(acc, :id, String.trim_leading(line, "id: "))

          true ->
            acc
        end
      end)

    if map_size(result) > 0 and (Map.has_key?(result, :event) or Map.has_key?(result, :data)) do
      result
    else
      nil
    end
  end
end
