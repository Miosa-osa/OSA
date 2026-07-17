defmodule OptimalSystemAgent.Agent.Loop.PermissionTierTest do
  @moduledoc """
  Regression for #4: set_permission_tier/2 advertises :subagent as a valid tier
  but the handle_call guard omitted it and there was no catch-all clause, so
  passing the documented :subagent value raised FunctionClauseError and killed
  the live session GenServer. It must now succeed, and an unknown tier must be
  rejected without crashing the session.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  setup do
    session_id = "perm-tier-test-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: session_id, channel: :test}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    %{session_id: session_id, pid: pid}
  end

  test "accepts the documented :subagent tier without crashing the session", ctx do
    assert {:ok, :subagent} = Loop.set_permission_tier(ctx.session_id, :subagent)
    assert Process.alive?(ctx.pid)
    assert {:ok, :subagent} = GenServer.call(ctx.pid, {:get_permission_tier})
  end

  test "accepts the existing tiers", ctx do
    for tier <- [:full, :workspace, :read_only, :auto] do
      assert {:ok, ^tier} = Loop.set_permission_tier(ctx.session_id, tier)
    end
  end

  test "rejects an unknown tier without killing the GenServer", ctx do
    assert {:error, :invalid_tier} = Loop.set_permission_tier(ctx.session_id, :bogus)
    assert Process.alive?(ctx.pid)
  end
end
