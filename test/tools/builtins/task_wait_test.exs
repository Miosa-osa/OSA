defmodule OptimalSystemAgent.Tools.Builtins.TaskWaitTest do
  @moduledoc """
  P5 — join-barrier (`task_wait`) regression tests: blocks until chosen
  previously-backgrounded agents finish then returns their results, and the
  blocking-wait-depth ceiling rejects over-deep nesting (grok
  `parent_blocking_wait_depth` parity).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.TaskWait.{Depth, Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_task_wait_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end

  defp ctx(session_id), do: %{UseContext.empty() | session_id: session_id}

  # ── Tool identity / schema ──────────────────────────────────────────────

  describe "Tool" do
    test "name/0 returns 'task_wait'" do
      assert Tool.name() == "task_wait"
    end

    test "parameters/0 requires agent_ids" do
      params = Tool.parameters()
      assert params["required"] == ["agent_ids"]
      assert params["properties"]["agent_ids"]["type"] == "array"
    end

    test "read_only?/2 is true" do
      assert Tool.read_only?(%{}, UseContext.empty())
    end

    test "destructive?/2 is false" do
      refute Tool.destructive?(%{}, UseContext.empty())
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts a non-empty array of strings" do
      assert {:ok, _} = Handler.validate(%{"agent_ids" => ["agent:a:1"]}, UseContext.empty())
    end

    test "rejects a missing agent_ids" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "agent_ids"
    end

    test "rejects an empty array" do
      assert {:error, _, -32_602} = Handler.validate(%{"agent_ids" => []}, UseContext.empty())
    end

    test "rejects a non-string element" do
      assert {:error, _, -32_602} =
               Handler.validate(%{"agent_ids" => ["ok", 5]}, UseContext.empty())
    end
  end

  # ── Handler.execute/2 — join-barrier behavior ────────────────────────────

  describe "Handler.execute/2 join-barrier" do
    test "returns immediately when all requested agents are already terminal" do
      RunStore.start_run(%{agent_id: "agent:p:1", parent_session_id: "p", role: "worker"})
      RunStore.complete("agent:p:1", %{status: :completed, summary: "done A"})

      RunStore.start_run(%{agent_id: "agent:p:2", parent_session_id: "p", role: "worker"})
      RunStore.complete("agent:p:2", %{status: :completed, summary: "done B"})

      {elapsed, {:ok, text}} =
        :timer.tc(fn ->
          Handler.execute(%{"agent_ids" => ["agent:p:1", "agent:p:2"]}, ctx("p"))
        end)

      # Both already terminal — must not block on the poll interval.
      assert elapsed < 400_000
      assert text =~ "done A"
      assert text =~ "done B"
    end

    test "blocks until a still-running agent transitions to terminal" do
      RunStore.start_run(%{agent_id: "agent:p:slow", parent_session_id: "p", role: "worker"})

      spawn(fn ->
        Process.sleep(300)
        RunStore.complete("agent:p:slow", %{status: :completed, summary: "finished late"})
      end)

      {elapsed, {:ok, text}} =
        :timer.tc(fn ->
          Handler.execute(%{"agent_ids" => ["agent:p:slow"], "timeout_ms" => 5_000}, ctx("p"))
        end)

      assert elapsed >= 250_000
      assert text =~ "finished late"
    end

    test "require_all: false returns as soon as ANY one agent finishes" do
      RunStore.start_run(%{agent_id: "agent:p:fast", parent_session_id: "p", role: "worker"})
      RunStore.complete("agent:p:fast", %{status: :completed, summary: "fast done"})
      RunStore.start_run(%{agent_id: "agent:p:neverdone", parent_session_id: "p", role: "worker"})

      {:ok, text} =
        Handler.execute(
          %{
            "agent_ids" => ["agent:p:fast", "agent:p:neverdone"],
            "require_all" => false,
            "timeout_ms" => 300
          },
          ctx("p")
        )

      assert text =~ "fast done"
      assert text =~ "still running"
    end

    test "times out and reports still-running agents rather than hanging forever" do
      RunStore.start_run(%{agent_id: "agent:p:stuck", parent_session_id: "p", role: "worker"})

      {elapsed, {:ok, text}} =
        :timer.tc(fn ->
          Handler.execute(%{"agent_ids" => ["agent:p:stuck"], "timeout_ms" => 200}, ctx("p"))
        end)

      assert elapsed < 2_000_000
      assert text =~ "still running"
    end

    test "an unknown agent id does not block the join and is reported clearly" do
      {:ok, text} = Handler.execute(%{"agent_ids" => ["agent:p:ghost"]}, ctx("p"))
      assert text =~ "No run found"
    end

    test "deregisters the blocked-wait entry after completion (no leak)" do
      RunStore.start_run(%{agent_id: "agent:p:leak", parent_session_id: "p", role: "worker"})
      RunStore.complete("agent:p:leak", %{status: :completed, summary: "ok"})

      Handler.execute(%{"agent_ids" => ["agent:p:leak"]}, ctx("caller-x"))

      refute Depth.blocked?("caller-x")
    end
  end

  # ── Depth ceiling (P5 join-barrier deadlock/starvation guard) ───────────

  describe "Depth ceiling" do
    setup do
      # Build a chain: caller -> parent1 -> parent2 -> parent3 in RunStore,
      # each currently registered as "blocked" in a task_wait, to simulate
      # nested joins (an agent waited-on by another waiter, N levels deep).
      RunStore.start_run(%{agent_id: "chain:1", parent_session_id: "top", role: "a"})
      RunStore.start_run(%{agent_id: "chain:2", parent_session_id: "chain:1", role: "b"})
      RunStore.start_run(%{agent_id: "chain:3", parent_session_id: "chain:2", role: "c"})

      on_exit(fn ->
        Depth.exit_wait("chain:1")
        Depth.exit_wait("chain:2")
        Depth.exit_wait("chain:3")
      end)

      :ok
    end

    test "current_depth/1 is 0 with no blocked ancestors" do
      assert Depth.current_depth("chain:3") == 0
    end

    test "current_depth/1 counts blocked ancestors along the parent chain" do
      Depth.enter("chain:1")
      Depth.enter("chain:2")

      assert Depth.current_depth("chain:3") == 2
    end

    test "check_permissions/2 denies once the wait would exceed the ceiling" do
      max = Depth.max_depth()

      # Register `max` blocked ancestors directly above "chain:3" so the NEXT
      # wait (this call, +1) would exceed the ceiling.
      levels = for n <- 1..max, do: "chain:anc#{n}"

      levels
      |> Enum.zip(["top" | levels])
      |> Enum.each(fn {id, parent} ->
        RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "anc"})
      end)

      RunStore.start_run(%{
        agent_id: "chain:leaf",
        parent_session_id: List.last(levels),
        role: "leaf"
      })

      Enum.each(levels, &Depth.enter/1)

      on_exit(fn -> Enum.each(levels, &Depth.exit_wait/1) end)

      assert {:deny, msg} =
               Handler.check_permissions(%{"agent_ids" => ["x"]}, ctx("chain:leaf"))

      assert msg =~ "ceiling"
    end

    test "check_permissions/2 allows a wait below the ceiling" do
      assert {:allow, _} = Handler.check_permissions(%{"agent_ids" => ["x"]}, ctx("chain:3"))
    end
  end
end
