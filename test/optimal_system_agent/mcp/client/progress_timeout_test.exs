defmodule OptimalSystemAgent.MCP.Client.ProgressTimeoutTest do
  @moduledoc """
  Verifies `onprogress` timeout-reset (opencode `resetTimeoutOnProgress`): a
  long-running tool call that keeps emitting `notifications/progress` must NOT
  trip its request timeout, because each progress notification re-arms the
  timer. A control call with no progress and no reply still times out.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ServerSession
  alias OptimalSystemAgent.MCP.Config.Server

  # Transport that, on tools/call, drips progress notifications (carrying the
  # request's progressToken) before finally replying AFTER the original timeout
  # would have elapsed. A `slow_no_progress` tool instead stays silent.
  defmodule ProgressTransport do
    @moduledoc false
    @behaviour OptimalSystemAgent.MCP.Transport
    use GenServer

    alias OptimalSystemAgent.MCP.Protocol.JSONRPC

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def send_message(pid, bin), do: GenServer.cast(pid, {:send, bin})

    @impl true
    def init(opts) do
      {:ok, %{owner: Keyword.fetch!(opts, :owner), ref: Keyword.fetch!(opts, :ref)}}
    end

    @impl true
    def handle_cast({:send, bin}, state) do
      case JSONRPC.decode(bin) do
        {:ok, {:request, id, "initialize", _}} ->
          reply(state, JSONRPC.response(id, %{"serverInfo" => %{"name" => "prog"}}))

        {:ok, {:request, id, "tools/list", _}} ->
          reply(state, JSONRPC.response(id, %{"tools" => [tool("slow"), tool("silent")]}))

        {:ok, {:request, id, "tools/call", params}} ->
          token = get_in(params, ["_meta", "progressToken"])
          handle_call_tool(get_in(params, ["name"]), id, token, state)

        _ ->
          :ok
      end

      {:noreply, state}
    end

    # "slow": progress at 150ms & 300ms keeps the 250ms-timeout call alive, then
    # reply at 400ms (> 250ms). "silent": never replies.
    defp handle_call_tool("slow", id, token, state) do
      send_progress(state, token, 150)
      send_progress(state, token, 300)
      Process.send_after(self(), {:final, id}, 400)
    end

    defp handle_call_tool(_other, _id, _token, _state), do: :ok

    @impl true
    def handle_info({:progress, token}, state) do
      reply(state, JSONRPC.notification("notifications/progress", %{"progressToken" => token}))
      {:noreply, state}
    end

    def handle_info({:final, id}, state) do
      reply(state, JSONRPC.response(id, %{"content" => [%{"type" => "text", "text" => "done"}]}))
      {:noreply, state}
    end

    defp send_progress(_state, nil, _delay), do: :ok
    defp send_progress(_state, token, delay), do: Process.send_after(self(), {:progress, token}, delay)

    defp tool(name), do: %{"name" => name, "description" => name, "inputSchema" => %{}}

    defp reply(state, msg) do
      {:ok, json} = JSONRPC.encode(msg)
      send(state.owner, {:mcp_message, state.ref, json})
    end
  end

  setup do
    prev = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, ProgressTransport)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :mcp_stdio_transport, prev),
        else: Application.delete_env(:optimal_system_agent, :mcp_stdio_transport)
    end)

    name = "prog_#{System.unique_integer([:positive])}"
    {:ok, pid} = ServerSession.start_link(%Server{name: name, transport: :stdio, command: "x"})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert wait_until(fn -> ServerSession.status(name) == :ready end)

    {:ok, name: name}
  end

  test "progress notifications reset the call timeout so a long call succeeds", %{name: name} do
    # 250ms nominal timeout, but progress at 150ms/300ms keeps re-arming it; the
    # reply arrives at ~400ms and must still be delivered.
    assert {:ok, %{"content" => [%{"type" => "text", "text" => "done"}]}} =
             ServerSession.call_tool(name, "slow", %{}, 250)
  end

  test "a silent call with no progress still times out", %{name: name} do
    assert {:error, :timeout} = ServerSession.call_tool(name, "silent", %{}, 150)
  end

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true ->
        Process.sleep(20)
        wait_until(fun, retries - 1)
    end
  end
end
