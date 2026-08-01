defmodule OptimalSystemAgent.MCP.Client.ProgressTimeoutTest do
  @moduledoc """
  Verifies `onprogress` timeout-reset (opencode `resetTimeoutOnProgress`): a
  long-running tool call that keeps emitting `notifications/progress` must NOT
  trip its request timeout, because each progress notification re-arms the
  timer. A control call with no progress and no reply still times out.

  ## Why this test is structural rather than timed

  The original version raced three real timers against a 250 ms request
  timeout: progress notifications were scheduled at 150 ms/300 ms and the reply
  at 400 ms, and the assertion was "the call returned `{:ok, _}`, therefore the
  timer must have been re-armed". On a loaded machine the 250 ms timer could
  win against the 150 ms notification purely because of scheduling, so the test
  went red with no production defect — and it could equally go *green* for the
  wrong reason on a machine where every deadline slipped together.

  The property under test has nothing to do with wall-clock duration. It is:

    * on progress, the pending call's *existing* deadline is destroyed, and
    * a *fresh* deadline of the full original timeout is armed in its place,
    * with the stored timeout left unchanged (so it can re-arm again), and
    * a reply arriving after all of that is still delivered to the caller.

  All of these are observable directly from the timer reference held in
  `ServerSession`'s pending map, so the test drives the transport explicitly
  from the test process and asserts on timer identity instead of elapsed time.
  Nothing here has to happen "fast enough".
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ServerSession
  alias OptimalSystemAgent.MCP.Config.Server

  # Deliberately long: the test never waits for it, it only reads it back off
  # the armed timer. A large value makes "the new timer carries the full
  # timeout" checkable with an enormous slop margin (see @full_timeout_slack).
  @call_timeout 60_000

  # How much of @call_timeout may have burned down between the session arming
  # the fresh timer and this process reading it. A full second of scheduling
  # delay across two adjacent statements is far beyond anything CPU contention
  # produces; well below that, the assertion still catches a re-arm that used a
  # shortened timeout.
  @full_timeout_slack 1_000

  # Transport driven entirely by the test process: on `tools/call` it reports
  # the request id and progressToken back to the test and then does nothing.
  # The test decides when a progress notification or the final reply happens,
  # so no assertion depends on a race between two `send_after`s.
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
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         ref: Keyword.fetch!(opts, :ref),
         test_pid: Application.fetch_env!(:optimal_system_agent, :mcp_progress_test_pid)
       }}
    end

    @impl true
    def handle_cast({:send, bin}, state) do
      case JSONRPC.decode(bin) do
        {:ok, {:request, id, "initialize", _}} ->
          reply(state, JSONRPC.response(id, %{"serverInfo" => %{"name" => "prog"}}))

        {:ok, {:request, id, "tools/list", _}} ->
          reply(state, JSONRPC.response(id, %{"tools" => [tool("slow"), tool("silent")]}))

        {:ok, {:request, id, "tools/call", params}} ->
          send(
            state.test_pid,
            {:saw_call, self(), get_in(params, ["name"]), id,
             get_in(params, ["_meta", "progressToken"])}
          )

        _ ->
          :ok
      end

      {:noreply, state}
    end

    # ── Test-driven emissions ──

    @impl true
    def handle_info({:emit_progress, token}, state) do
      reply(state, JSONRPC.notification("notifications/progress", %{"progressToken" => token}))
      {:noreply, state}
    end

    def handle_info({:emit_reply, id}, state) do
      reply(state, JSONRPC.response(id, %{"content" => [%{"type" => "text", "text" => "done"}]}))
      {:noreply, state}
    end

    def handle_info(_other, state), do: {:noreply, state}

    defp tool(name), do: %{"name" => name, "description" => name, "inputSchema" => %{}}

    defp reply(state, msg) do
      {:ok, json} = JSONRPC.encode(msg)
      send(state.owner, {:mcp_message, state.ref, json})
    end
  end

  setup do
    prev = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, ProgressTransport)
    Application.put_env(:optimal_system_agent, :mcp_progress_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :mcp_progress_test_pid)

      if prev,
        do: Application.put_env(:optimal_system_agent, :mcp_stdio_transport, prev),
        else: Application.delete_env(:optimal_system_agent, :mcp_stdio_transport)
    end)

    name = "prog_#{System.unique_integer([:positive])}"
    {:ok, pid} = ServerSession.start_link(%Server{name: name, transport: :stdio, command: "x"})
    # The session traps exits and is linked to this (transient) test process,
    # so it may already be terminating by cleanup time; kill tolerantly.
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert wait_until(fn -> ServerSession.status(name) == :ready end)

    {:ok, name: name, session: pid}
  end

  test "a progress notification destroys the in-flight deadline and arms a fresh full one",
       %{name: name, session: session} do
    task = Task.async(fn -> ServerSession.call_tool(name, "slow", %{}, @call_timeout) end)

    assert_receive {:saw_call, transport, "slow", id, token}, 5_000

    assert token == id,
           "the call must carry a progressToken keyed to the request, otherwise no " <>
             "progress notification could ever be matched back to this call"

    {timer_before, timeout_before} = await_pending(session, id)
    assert timeout_before == @call_timeout

    send(transport, {:emit_progress, token})

    {timer_after, timeout_after} =
      await_pending(session, id, fn {timer, _timeout} -> timer != timer_before end)

    # 1. The deadline was replaced, not merely extended in place.
    refute timer_after == timer_before

    # 2. The old deadline can no longer fire: a cancelled timer reads as false.
    assert Process.read_timer(timer_before) == false,
           "the pre-progress timer is still live — it will time out the call regardless of progress"

    # 3. The replacement carries the *full* original timeout, not a remainder.
    remaining = Process.read_timer(timer_after)

    assert is_integer(remaining) and remaining > @call_timeout - @full_timeout_slack,
           "re-armed timer has #{inspect(remaining)}ms left, expected ~#{@call_timeout}ms"

    # 4. The stored timeout is untouched, so the *next* progress re-arms by as
    #    much again — this is what makes the reset unbounded rather than one-shot.
    assert timeout_after == @call_timeout

    # 5. And the reply, which only arrives after all of the above, is delivered.
    send(transport, {:emit_reply, id})

    assert {:ok, %{"content" => [%{"type" => "text", "text" => "done"}]}} =
             Task.await(task, 5_000)
  end

  test "progress carrying an unknown token leaves the pending call's deadline alone",
       %{name: name, session: session} do
    task = Task.async(fn -> ServerSession.call_tool(name, "slow", %{}, @call_timeout) end)

    assert_receive {:saw_call, transport, "slow", id, _token}, 5_000
    {timer_before, _} = await_pending(session, id)

    send(transport, {:emit_progress, "not-a-pending-token"})
    # Flush both hops (test → transport → session) so "unchanged" means the
    # notification was processed and ignored, not that it is still in flight.
    _ = :sys.get_state(transport)
    _ = :sys.get_state(session)

    {timer_after, _} = await_pending(session, id)
    assert timer_after == timer_before

    send(transport, {:emit_reply, id})
    assert {:ok, _} = Task.await(task, 5_000)
  end

  test "a silent call with no progress still times out", %{name: name} do
    assert {:error, :timeout} = ServerSession.call_tool(name, "silent", %{}, 150)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Reads the ServerSession's pending entry for request `id`, retrying until it
  # exists and satisfies `pred`. Returns `{timer, timeout}`.
  defp await_pending(session, id, pred \\ fn _ -> true end, retries \\ 200) do
    entry =
      case :sys.get_state(session).pending do
        %{^id => {_from, timer, timeout}} -> {timer, timeout}
        _ -> nil
      end

    cond do
      entry != nil and pred.(entry) ->
        entry

      retries <= 0 ->
        flunk("no pending entry for request #{inspect(id)} matching the expected shape")

      true ->
        Process.sleep(10)
        await_pending(session, id, pred, retries - 1)
    end
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
