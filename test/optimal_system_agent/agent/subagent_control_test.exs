defmodule OptimalSystemAgent.Agent.SubagentControlTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.{ExecutionControl, SubagentControl}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "osa-subagent-control-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, dir)
    :ets.delete(:osa_agent_pause_flags, "worker")

    on_exit(fn ->
      :ets.delete(:osa_agent_pause_flags, "worker")
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, previous),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)
    end)

    :ok = ExecutionControl.start("worker", %{parent_session_id: "parent", task: "Work"})
    :ok
  end

  test "snapshot exposes controls appropriate to the durable lifecycle" do
    assert {:ok, snapshot} = SubagentControl.snapshot("worker")
    assert "cancel_tool" in snapshot.available_controls
    assert "reassign" in snapshot.available_controls
    refute "resume" in snapshot.available_controls
  end

  test "pause records an operator-visible durable state" do
    assert {:ok, snapshot} = SubagentControl.command("worker", :pause)
    assert snapshot.status == "paused"
    assert snapshot.recovery_state == "operator_paused"
    assert snapshot.available_controls == ~w(resume stop reassign)
    assert :ets.lookup(:osa_agent_pause_flags, "worker") == [{"worker", true}]
  end

  test "unsupported commands fail without changing state" do
    assert {:error, {:unsupported_action, "teleport"}} =
             SubagentControl.command("worker", "teleport")

    assert ExecutionControl.get("worker").status == "running"
  end

  test "a known command fails when the durable state does not allow it" do
    assert {:error, {:invalid_action_for_status, "resume", "running"}} =
             SubagentControl.command("worker", "resume")
  end
end
