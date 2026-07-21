defmodule OptimalSystemAgent.MCP.Client.QuietBootTest do
  @moduledoc """
  A fresh install often has ~16 auto-discovered MCP servers, many optional or
  misconfigured. Boot must stay CALM: the expected per-server connect/handshake
  failures are debug (not a wall of warnings), and the Manager emits ONE summary
  line. These tests pin both halves:

    * `boot_summary_line/1` counts ready vs unavailable correctly (0 / all /
      partial), and
    * a permanently-failing server logs its boot failures at DEBUG, not WARNING
      (proven with `ExUnit.CaptureLog` level filtering).

  Everything is driven through an injected stub transport so it is deterministic:
  no real npx, no network, no daemon.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.MCP.Client.{Manager, ServerSession}
  alias OptimalSystemAgent.MCP.Config.Server

  # A transport whose start_link ALWAYS fails, exercising the `connect/1`
  # `{:error, reason}` branch (the executable-not-found / package-404 case) that
  # logs "transport failed to start" and ultimately "going dormant".
  defmodule AlwaysFailsTransport do
    @moduledoc false
    @behaviour OptimalSystemAgent.MCP.Transport

    @impl true
    def start_link(_opts), do: {:error, :always_fails}

    @impl true
    def send_message(_transport, _message), do: {:error, :no_transport}
  end

  setup do
    # The session links to us (its caller); trap exits so a killed session never
    # takes the test process down.
    Process.flag(:trap_exit, true)

    prev_transport = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
    prev_cap = Application.get_env(:optimal_system_agent, :mcp_max_connect_failures)
    prev_base = Application.get_env(:optimal_system_agent, :mcp_initial_backoff_ms)
    prev_max = Application.get_env(:optimal_system_agent, :mcp_max_backoff_ms)

    # Tiny cap + backoff so a failing server reaches :dormant in milliseconds.
    Application.put_env(:optimal_system_agent, :mcp_stdio_transport, AlwaysFailsTransport)
    Application.put_env(:optimal_system_agent, :mcp_max_connect_failures, 3)
    Application.put_env(:optimal_system_agent, :mcp_initial_backoff_ms, 2)
    Application.put_env(:optimal_system_agent, :mcp_max_backoff_ms, 4)

    on_exit(fn ->
      restore(:mcp_stdio_transport, prev_transport)
      restore(:mcp_max_connect_failures, prev_cap)
      restore(:mcp_initial_backoff_ms, prev_base)
      restore(:mcp_max_backoff_ms, prev_max)
    end)

    :ok
  end

  describe "boot_summary_line/1" do
    test "all connected omits the unavailable note" do
      assert Manager.boot_summary_line([{"a", :ready}, {"b", :ready}]) ==
               "[MCP] connected 2 of 2 servers"
    end

    test "none connected reports every server as unavailable" do
      assert Manager.boot_summary_line([{"a", :dormant}, {"b", :down}]) ==
               "[MCP] connected 0 of 2 servers (2 unavailable, run 'osa doctor' for details)"
    end

    test "partial connect reports only the unavailable remainder" do
      statuses = [{"a", :ready}, {"b", :connecting}, {"c", :dormant}]

      assert Manager.boot_summary_line(statuses) ==
               "[MCP] connected 1 of 3 servers (2 unavailable, run 'osa doctor' for details)"
    end
  end

  describe "per-server boot failures are debug, not warning" do
    test "a permanently-failing server logs nothing at :warning but still at :debug" do
      # The suite pins the primary Logger level to :warning (config/test.exs),
      # which would drop debug entirely; raise it to :debug for this test so we
      # can prove the lines EXIST at debug, then use capture_log's own `:level`
      # filter to simulate the operator's default warning-level view.
      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      # Operator's default view (warning+): the expected boot-failure lines must
      # be absent — a calm boot, not a wall of red.
      name = "quiet_warn_#{System.unique_integer([:positive])}"

      warn_log =
        capture_log([level: :warning], fn ->
          drive_to_dormant(name)
        end)

      refute warn_log =~ "transport failed to start"
      refute warn_log =~ "going dormant"

      # At :debug the SAME lines are still present, so the detail is only moved
      # out of the default boot path, not lost.
      name2 = "quiet_debug_#{System.unique_integer([:positive])}"

      debug_log =
        capture_log([level: :debug], fn ->
          drive_to_dormant(name2)
        end)

      assert debug_log =~ "transport failed to start"
      assert debug_log =~ "going dormant"
    end
  end

  # Start a session on the AlwaysFailsTransport and wait until it is dormant.
  defp drive_to_dormant(name) do
    server = %Server{name: name, transport: :stdio, command: "irrelevant"}
    {:ok, pid} = ServerSession.start_link(server)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert wait_until(fn -> ServerSession.status(name) == :dormant end)
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true ->
        Process.sleep(5)
        wait_until(fun, retries - 1)
    end
  end
end
