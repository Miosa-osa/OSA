defmodule OptimalSystemAgent.MCP.Client.ReconnectCapTest do
  @moduledoc """
  Verifies the bounded auto-connect that makes discovery's auto-load safe.

  A `ServerSession` for a permanently-broken server must make a BOUNDED burst of
  connect attempts and then go `:dormant` — never the unbounded npx-spawn loop
  that previously blew the MCP supervisor's restart budget and cascaded to the
  app root. It also traps exits so a LINKED transport crash routes through the
  capped reconnect path instead of taking the session down (which would let the
  DynamicSupervisor restart it fresh and reset the failure counter).

  Everything here is driven through injected stub transports so it is fully
  deterministic: no real npx, no network, no daemon.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ServerSession
  alias OptimalSystemAgent.MCP.Config.Server

  # A transport whose start_link ALWAYS fails, exercising the `connect/1`
  # `{:error, reason}` branch (the executable-not-found / package-404 case).
  # Each attempt pings a test reporter pid so the test can count attempts
  # precisely instead of racing on timing.
  defmodule AlwaysFailsTransport do
    @moduledoc false
    @behaviour OptimalSystemAgent.MCP.Transport

    @impl true
    def start_link(_opts) do
      case Application.get_env(:optimal_system_agent, :reconnect_test_reporter) do
        pid when is_pid(pid) -> send(pid, :connect_attempt)
        _ -> :ok
      end

      {:error, :always_fails}
    end

    @impl true
    def send_message(_transport, _message), do: {:error, :no_transport}
  end

  # A transport that starts a real (linked) process and then stays silent: it
  # never answers `initialize`, so the session sits in `:connecting` with a live
  # `state.transport`. Killing that process delivers a genuine `{:EXIT, ...}` to
  # the trapping session.
  defmodule SilentTransport do
    @moduledoc false
    @behaviour OptimalSystemAgent.MCP.Transport
    use GenServer

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def send_message(_transport, _message), do: :ok

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
  end

  setup do
    # The session links to us (its caller). Trap exits so a session that stops
    # with :shutdown (the teardown test) delivers an {:EXIT, ...} message instead
    # of killing the test process.
    Process.flag(:trap_exit, true)

    prev_transport = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
    prev_cap = Application.get_env(:optimal_system_agent, :mcp_max_connect_failures)
    prev_base = Application.get_env(:optimal_system_agent, :mcp_initial_backoff_ms)
    prev_max = Application.get_env(:optimal_system_agent, :mcp_max_backoff_ms)
    prev_reporter = Application.get_env(:optimal_system_agent, :reconnect_test_reporter)

    on_exit(fn ->
      restore(:mcp_stdio_transport, prev_transport)
      restore(:mcp_max_connect_failures, prev_cap)
      restore(:mcp_initial_backoff_ms, prev_base)
      restore(:mcp_max_backoff_ms, prev_max)
      restore(:reconnect_test_reporter, prev_reporter)
    end)

    :ok
  end

  test "a permanently failing server goes dormant after exactly the cap and stops reconnecting" do
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, AlwaysFailsTransport)
    Application.put_env(:optimal_system_agent, :mcp_max_connect_failures, 5)
    # Tiny backoff so the five attempts happen in milliseconds.
    Application.put_env(:optimal_system_agent, :mcp_initial_backoff_ms, 2)
    Application.put_env(:optimal_system_agent, :mcp_max_backoff_ms, 8)
    Application.put_env(:optimal_system_agent, :reconnect_test_reporter, self())

    name = "always_fail_#{System.unique_integer([:positive])}"
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}

    {:ok, pid} = ServerSession.start_link(server)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # Exactly @max_connect_failures connect attempts are made, then it stops.
    for _ <- 1..5, do: assert_receive(:connect_attempt, 2_000)

    assert wait_until(fn -> ServerSession.status(name) == :dormant end)

    # No sixth attempt: dormancy means no further `:reconnect` is scheduled.
    refute_receive :connect_attempt, 200

    # The session did NOT crash — it is quietly dormant and still registered.
    assert Process.alive?(pid)
    assert ServerSession.status(name) == :dormant
  end

  test "a linked transport crash does not kill the session and counts toward the cap" do
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, SilentTransport)
    Application.put_env(:optimal_system_agent, :mcp_max_connect_failures, 5)
    # Large backoff so the post-crash reconnect does NOT fire during the
    # assertion window — the failure count stays at exactly 1.
    Application.put_env(:optimal_system_agent, :mcp_initial_backoff_ms, 60_000)
    Application.put_env(:optimal_system_agent, :mcp_max_backoff_ms, 60_000)

    name = "crash_#{System.unique_integer([:positive])}"
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}

    {:ok, pid} = ServerSession.start_link(server)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # Wait for the transport to be established (session is :connecting with a
    # live linked transport pid).
    assert wait_until(fn -> is_pid(:sys.get_state(pid).transport) end)
    transport = :sys.get_state(pid).transport
    assert 0 == :sys.get_state(pid).fail_count

    # Genuinely crash the linked transport. The session traps exits, so this is
    # delivered as {:EXIT, transport, :killed}.
    Process.exit(transport, :kill)

    assert wait_until(fn -> :sys.get_state(pid).fail_count == 1 end)
    assert Process.alive?(pid)
    # Still alive and reconnecting (not dormant, cap not reached).
    refute ServerSession.status(name) == :dormant
  end

  test "a stability mark resets the failure count so a recovered server is not penalized" do
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, SilentTransport)
    Application.put_env(:optimal_system_agent, :mcp_max_connect_failures, 5)

    name = "recover_#{System.unique_integer([:positive])}"
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}

    {:ok, pid} = ServerSession.start_link(server)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert wait_until(fn -> is_pid(:sys.get_state(pid).transport) end)

    # Simulate a server that flapped a few times but is now up and stable:
    # non-zero fail_count, status :ready. Then the stability timer fires
    # (`{:mark_stable, conn_gen}`) and must zero the counter.
    gen = :sys.get_state(pid).conn_gen
    :sys.replace_state(pid, fn state -> %{state | status: :ready, fail_count: 3} end)

    send(pid, {:mark_stable, gen})

    assert wait_until(fn -> :sys.get_state(pid).fail_count == 0 end)
    assert Process.alive?(pid)
  end

  test "a normal transport shutdown stops the session cleanly (no reconnect)" do
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, SilentTransport)
    Application.put_env(:optimal_system_agent, :mcp_max_connect_failures, 5)

    name = "shutdown_#{System.unique_integer([:positive])}"
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}

    {:ok, pid} = ServerSession.start_link(server)

    assert wait_until(fn -> is_pid(:sys.get_state(pid).transport) end)
    transport = :sys.get_state(pid).transport

    # A deliberate teardown of the linked transport (:shutdown) must stop the
    # session, NOT turn into a reconnect.
    Process.exit(transport, :shutdown)

    assert wait_until(fn -> not Process.alive?(pid) end)
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end
end
