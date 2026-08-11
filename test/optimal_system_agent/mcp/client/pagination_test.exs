defmodule OptimalSystemAgent.MCP.Client.PaginationTest do
  @moduledoc """
  Drives a `ServerSession` handshake over a canned transport that paginates its
  `tools/list` across multiple pages, verifying the cursor loop accumulates all
  pages and that a repeated cursor terminates the loop (dup-cursor guard) rather
  than spinning forever.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ServerSession
  alias OptimalSystemAgent.MCP.Config.Server

  # A transport that returns tools/list in pages. The first page (no cursor)
  # yields `tool_a` + nextCursor "c1"; the "c1" page yields `tool_b` and repeats
  # nextCursor "c1" — a server paginating in a loop. The session must fetch page
  # two then STOP on the duplicate cursor, finalizing with both tools.
  defmodule PaginatingTransport do
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
          reply(state, JSONRPC.response(id, %{"serverInfo" => %{"name" => "paged"}}))

        {:ok, {:request, id, "tools/list", params}} ->
          reply(state, JSONRPC.response(id, page(params["cursor"])))

        _ ->
          :ok
      end

      {:noreply, state}
    end

    # First page: tool_a + cursor c1. Any cursor: tool_b + cursor c1 (repeat).
    defp page(nil) do
      %{"tools" => [tool("tool_a")], "nextCursor" => "c1"}
    end

    defp page(_cursor) do
      %{"tools" => [tool("tool_b")], "nextCursor" => "c1"}
    end

    defp tool(name), do: %{"name" => name, "description" => name, "inputSchema" => %{}}

    defp reply(state, msg) do
      {:ok, json} = JSONRPC.encode(msg)
      send(state.owner, {:mcp_message, state.ref, json})
    end
  end

  setup do
    prev = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, PaginatingTransport)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :mcp_stdio_transport, prev),
        else: Application.delete_env(:optimal_system_agent, :mcp_stdio_transport)
    end)

    :ok
  end

  test "accumulates paginated tools and stops on a duplicate cursor" do
    name = "paged_#{System.unique_integer([:positive])}"
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}

    {:ok, pid} = ServerSession.start_link(server)
    # The session traps exits and is linked to this (transient) test process,
    # so it may already be terminating by cleanup time; kill tolerantly.
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert wait_until(fn -> ServerSession.status(name) == :ready end)
    assert wait_until(fn -> length(ServerSession.list_tools(name)) == 2 end)

    names = ServerSession.list_tools(name) |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["tool_a", "tool_b"]

    # The dup-cursor guard must have halted the loop: the session is still alive
    # and not stuck paginating.
    assert Process.alive?(pid)
    assert ServerSession.status(name) == :ready
  end

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, retries - 1)
    end
  end
end
