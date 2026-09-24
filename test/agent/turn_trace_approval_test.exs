defmodule OptimalSystemAgent.Agent.TurnTraceApprovalTest do
  @moduledoc """
  The approval park in `ToolExecutor.await_permission/4` is recorded on the
  turn's trace, so `/trace` can separate time spent waiting on the user from
  time the tool itself took.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.{Loop, TurnTrace}
  alias OptimalSystemAgent.Agent.Loop.{PermissionBroker, ToolExecutor}

  setup do
    prior = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
    Application.put_env(:optimal_system_agent, :interactive_permissions, true)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :interactive_permissions, prior) end)
    :ok
  end

  test "an answered approval and a timed-out one are both on the trace" do
    sid = "trace-approval-#{System.unique_integer([:positive])}"
    on_exit(fn -> TurnTrace.clear(sid) end)
    state = struct(Loop, session_id: sid, permission_mode: :ask)
    TurnTrace.begin_turn(sid)

    summary = %{args: "x", kind: "bash", timeout_ms: 2_000}
    tool_call = %{id: "tc-1", name: "shell_execute", arguments: %{"command" => "make"}}

    answered_id = PermissionBroker.new_request_id()

    spawn(fn ->
      Process.sleep(60)
      PermissionBroker.respond(answered_id, "allow_once")
    end)

    assert :allow = ToolExecutor.await_permission(tool_call, state, answered_id, summary)

    assert {:blocked, _} =
             ToolExecutor.await_permission(
               tool_call,
               state,
               PermissionBroker.new_request_id(),
               %{summary | timeout_ms: 50}
             )

    s = TurnTrace.latest(sid)
    assert s.approval.waits == 2
    assert s.approval.ms >= 100

    assert [%{outcome: "allow_once", wait_ms: first}, %{outcome: "timeout"}] = s.approval.items
    assert first >= 50
  end
end
