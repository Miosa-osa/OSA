defmodule OptimalSystemAgent.Agent.FleetResumerTest do
  @moduledoc """
  W3/D3 — unit tests for boot orphan recovery selection + re-dispatch coordination.

  All state is injected (fake run rows, fake liveness/posture/resume funs) so no
  real loop is booted.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.FleetResumer
  alias OptimalSystemAgent.Agent.RunStore

  defp run(id, attrs \\ %{}) do
    Map.merge(
      %{
        agent_id: id,
        parent_session_id: "root",
        role: "agent",
        task: "t",
        status: :running,
        started_at: DateTime.utc_now(),
        posture: :autonomous
      },
      attrs
    )
  end

  describe "qualifying_orphans/2 selection" do
    test "selects autonomous running runs whose process is gone" do
      runs = [run("a"), run("b")]

      selected =
        FleetResumer.qualifying_orphans(runs,
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end
        )

      assert Enum.map(selected, & &1.agent_id) |> Enum.sort() == ["a", "b"]
    end

    test "excludes runs whose process is still alive" do
      runs = [run("alive"), run("dead")]

      selected =
        FleetResumer.qualifying_orphans(runs,
          alive_fun: fn id -> id == "alive" end,
          posture_fun: fn _ -> true end
        )

      assert Enum.map(selected, & &1.agent_id) == ["dead"]
    end

    test "excludes non-autonomous posture runs (safe-by-default)" do
      runs = [run("auto", %{posture: :autonomous}), run("sup", %{posture: :supervised})]

      selected =
        FleetResumer.qualifying_orphans(runs,
          alive_fun: fn _ -> false end,
          posture_fun: fn r -> r.posture == :autonomous end
        )

      assert Enum.map(selected, & &1.agent_id) == ["auto"]
    end

    test "excludes non-running rows" do
      runs = [run("r", %{status: :running}), run("c", %{status: :completed})]

      selected =
        FleetResumer.qualifying_orphans(runs,
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end
        )

      assert Enum.map(selected, & &1.agent_id) == ["r"]
    end

    test "budget caps the number of selected runs" do
      runs = for n <- 1..10, do: run("r#{n}")

      selected =
        FleetResumer.qualifying_orphans(runs,
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end,
          budget: 3
        )

      assert length(selected) == 3
    end

    test "orders parents before their descendants (root-first)" do
      # child -> parent -> grandparent chain, given out of order.
      grandparent = run("gp", %{parent_session_id: "outside"})
      parent = run("p", %{parent_session_id: "gp"})
      child = run("c", %{parent_session_id: "p"})

      selected =
        FleetResumer.qualifying_orphans([child, parent, grandparent],
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end
        )

      assert Enum.map(selected, & &1.agent_id) == ["gp", "p", "c"]
    end
  end

  describe "resume_on_boot/1 coordination" do
    test "autonomous crash recovery is enabled by default and can be disabled" do
      isolate_store()
      previous = Application.get_env(:optimal_system_agent, :fleet_resume_on_boot)
      Application.delete_env(:optimal_system_agent, :fleet_resume_on_boot)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:optimal_system_agent, :fleet_resume_on_boot),
          else: Application.put_env(:optimal_system_agent, :fleet_resume_on_boot, previous)
      end)

      summary =
        FleetResumer.resume_on_boot(
          runs: [],
          alive_fun: fn _ -> false end
        )

      assert summary.enabled == true
    end

    test "when disabled, resumes nothing but still reconciles ghosts" do
      # Seed a stale running row in the real (test-isolated) RunStore.
      isolate_store()
      RunStore.start_run(%{agent_id: "ghost", parent_session_id: "p", role: "agent", task: "t"})

      summary =
        FleetResumer.resume_on_boot(
          enabled: false,
          alive_fun: fn _ -> false end
        )

      assert summary.enabled == false
      assert summary.resumed == []
      assert "ghost" in summary.reconciled
      assert %{status: :cancelled} = RunStore.get("ghost")
    end

    test "when enabled, re-dispatches qualifying orphans via the injected resume fun" do
      isolate_store()
      test_pid = self()

      runs = [run("orphan1"), run("orphan2")]

      summary =
        FleetResumer.resume_on_boot(
          enabled: true,
          runs: runs,
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end,
          resume_fun: fn id, _msg ->
            send(test_pid, {:resumed, id})
            {:ok, id}
          end
        )

      assert Enum.sort(summary.resumed) == ["orphan1", "orphan2"]
      assert summary.failed == []
      assert_received {:resumed, "orphan1"}
      assert_received {:resumed, "orphan2"}
    end

    test "resume failures are tracked separately, not raised" do
      isolate_store()

      summary =
        FleetResumer.resume_on_boot(
          enabled: true,
          runs: [run("bad")],
          alive_fun: fn _ -> false end,
          posture_fun: fn _ -> true end,
          resume_fun: fn _id, _msg -> {:error, :boom} end
        )

      assert summary.resumed == []
      assert summary.failed == ["bad"]
    end
  end

  # Point RunStore at an isolated temp dir + clean table for reconcile assertions.
  defp isolate_store do
    tmp = Path.join(System.tmp_dir!(), "osa_fleet_resumer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)
    RunStore.list()
    :ets.delete_all_objects(RunStore)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end
end
