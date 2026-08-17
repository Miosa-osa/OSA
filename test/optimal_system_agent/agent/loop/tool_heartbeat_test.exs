defmodule OptimalSystemAgent.Agent.Loop.ToolHeartbeatTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolHeartbeat

  test "emits periodic liveness and marks the stall threshold only once" do
    session_id = "heartbeat-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    pid =
      ToolHeartbeat.start(
        %{name: "slow_tool", id: "call-1"},
        %{session_id: session_id},
        interval_ms: 5,
        stalled_ms: 10
      )

    assert_receive {:osa_event, %{type: :tool_heartbeat, stalled: false}}, 100
    assert_receive {:osa_event, %{type: :tool_heartbeat, stalled: true}}, 100
    assert_receive {:osa_event, %{type: :tool_heartbeat, stalled: false}}, 100
    assert :ok = ToolHeartbeat.stop(pid)
  end
end
