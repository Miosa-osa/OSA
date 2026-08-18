defmodule OptimalSystemAgent.Agent.Loop.ToolOrchestratorStallTest do
  @moduledoc """
  A wedged tool call must never stall a turn in silence.

  `timeout_ms` defaults to `:infinity` (react_loop.ex) on purpose: a generic
  wrapper cannot know whether it is timing a 200 ms file read or a multi-agent
  dispatch that legitimately runs for hours, and an agent expected to work
  unattended must not be killed for taking a long time.

  The cost was total silence. Observed in the wild: a turn stopped dead after
  `serialising 2 of 4 batched call(s)`, the backend never logged another line,
  nothing was written to the session log, and the composer returned as though
  the turn had finished — while `/health` still answered 200. The turn was not
  dead, it was hung, and nothing said so.

  Duration is not the bug. Silence is.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator

  setup do
    previous = Application.fetch_env(:optimal_system_agent, :tool_stall_report_ms)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :tool_stall_report_ms, v)
        :error -> Application.delete_env(:optimal_system_agent, :tool_stall_report_ms)
      end
    end)

    :ok
  end

  describe "the reporting interval" do
    test "defaults to something a human would notice, not hours" do
      Application.delete_env(:optimal_system_agent, :tool_stall_report_ms)
      ms = ToolOrchestrator.stall_report_interval_ms()

      assert is_integer(ms)
      assert ms >= 10_000, "#{ms}ms would spam the log for every ordinary tool call"
      assert ms <= 300_000, "#{ms}ms is too long to wait before being told anything"
    end

    test "is configurable" do
      Application.put_env(:optimal_system_agent, :tool_stall_report_ms, 250)
      assert ToolOrchestrator.stall_report_interval_ms() == 250
    end
  end

  describe "a tool that outlives the interval" do
    test "is named in the log rather than hanging silently" do
      Application.put_env(:optimal_system_agent, :tool_stall_report_ms, 100)

      log =
        capture_log(fn ->
          run_blocking_dispatch(600)
        end)

      # The two things the operator needed and did not get: WHICH call, and
      # that it is still going.
      assert log =~ "still running", "no stall report: #{log}"
      assert log =~ "slow_probe", "the report did not name the tool: #{log}"
    end

    test "says it is not a timeout, because nothing was killed" do
      Application.put_env(:optimal_system_agent, :tool_stall_report_ms, 100)

      log = capture_log(fn -> run_blocking_dispatch(600) end)

      # A long-running dispatch must not be mistaken for a failure - the whole
      # point is that autonomy is preserved and nothing is capped.
      assert log =~ "Not a timeout", "the report reads like a kill: #{log}"
    end
  end

  describe "a tool that finishes promptly" do
    test "produces no stall noise" do
      Application.put_env(:optimal_system_agent, :tool_stall_report_ms, 60_000)

      log = capture_log(fn -> run_blocking_dispatch(10) end)

      refute log =~ "still running",
             "a fast tool must not be reported as stalled: #{log}"
    end
  end

  # Drive the orchestrator's collection loop with a task that sleeps, which is
  # the shape of a wedged call: alive, making no progress, never returning.
  defp run_blocking_dispatch(sleep_ms) do
    parent = self()

    task =
      Task.async(fn ->
        Process.sleep(sleep_ms)
        send(parent, :done)
        {:ok, "finished"}
      end)

    tc = %{id: "call_1", name: "slow_probe", arguments: "{}"}

    # Exercise the same poll/report path the real dispatch uses.
    :erlang.apply(ToolOrchestrator, :collect_tasks, [[{tc, task}], [], "sess-stall", :infinity, %{
      started: System.monotonic_time(:millisecond),
      last_report: System.monotonic_time(:millisecond)
    }])
  rescue
    UndefinedFunctionError ->
      # collect_tasks/5 is private; fall back to asserting via the public
      # interval accessor only. Flagged rather than silently passing.
      flunk("collect_tasks/5 is not reachable for testing — expose a seam")
  end
end
