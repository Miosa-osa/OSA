defmodule OptimalSystemAgent.Channels.CLI.CommandsPlanTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.CLI.Commands

  test "/plan toggles plan_mode_enabled on the live loop" do
    session_id = "cli-plan-test-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: session_id, channel: :test}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    refute loop_state(pid).plan_mode_enabled

    enabled_output =
      capture_io(fn ->
        assert ^session_id = Commands.dispatch("plan", session_id)
      end)

    assert enabled_output =~ "Plan mode"
    assert enabled_output =~ "enabled"
    assert loop_state(pid).plan_mode_enabled

    disabled_output =
      capture_io(fn ->
        assert ^session_id = Commands.dispatch("plan", session_id)
      end)

    assert disabled_output =~ "Plan mode"
    assert disabled_output =~ "disabled"
    refute loop_state(pid).plan_mode_enabled
  end

  defp loop_state(pid), do: :sys.get_state(pid)
end
