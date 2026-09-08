defmodule OptimalSystemAgent.Agent.Loop.CascadingCancelTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Shell.BackgroundManager

  @cancel_table :osa_cancel_flags

  # Unique root per test so RunStore/cancel-table state never bleeds across
  # cases (RunStore's ETS table is process-global and never test-scoped).
  defp sid(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  setup do
    :ets.new(@cancel_table, [:named_table, :public, read_concurrency: true])
    :ok
  rescue
    # already exists (created by app boot / another test) — fine.
    ArgumentError -> :ok
  end

  describe "descendant_session_ids/1 — BFS over RunStore parent chain" do
    test "finds children AND grandchildren (transitive, not just flat prefix)" do
      root = sid("root")
      child = "agent:#{root}:1"
      grandchild = "agent:#{child}:1"
      unrelated = sid("unrelated")
      unrelated_child = "agent:#{unrelated}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "agent", task: "t"})

      RunStore.start_run(%{
        agent_id: grandchild,
        parent_session_id: child,
        role: "agent",
        task: "t"
      })

      RunStore.start_run(%{
        agent_id: unrelated_child,
        parent_session_id: unrelated,
        role: "agent",
        task: "t"
      })

      descendants = Loop.descendant_session_ids(root)

      assert child in descendants
      assert grandchild in descendants
      refute unrelated_child in descendants
    end

    test "a cyclic/malformed parent chain terminates instead of looping forever" do
      a = sid("cyc-a")
      b = "agent:#{a}:1"
      # b's parent is a (normal), but we also feed in a malformed row where
      # `a`'s "parent" is `b` — creating a 2-cycle in the parent graph.
      RunStore.start_run(%{agent_id: b, parent_session_id: a, role: "agent", task: "t"})
      RunStore.start_run(%{agent_id: a, parent_session_id: b, role: "agent", task: "t"})

      {time_us, result} =
        :timer.tc(fn -> Loop.descendant_session_ids(a) end)

      # Must terminate quickly (no infinite loop) and must not include the
      # root itself twice or blow up.
      assert time_us < 2_000_000
      assert is_list(result)
      assert Enum.uniq(result) == result
    end

    test "root with no descendants returns an empty list" do
      root = sid("lonely")
      assert Loop.descendant_session_ids(root) == []
    end

    test "excludes a background-dispatched child AND its own subtree" do
      root = sid("bgexclude")
      attached_child = "agent:#{root}:attached"
      bg_child = "agent:#{root}:bg"
      bg_grandchild = "agent:#{bg_child}:1"

      RunStore.start_run(%{
        agent_id: attached_child,
        parent_session_id: root,
        role: "agent",
        task: "t"
      })

      RunStore.start_run(%{
        agent_id: bg_child,
        parent_session_id: root,
        role: "background",
        task: "t",
        background: true
      })

      RunStore.start_run(%{
        agent_id: bg_grandchild,
        parent_session_id: bg_child,
        role: "agent",
        task: "t"
      })

      descendants = Loop.descendant_session_ids(root)

      assert attached_child in descendants
      refute bg_child in descendants,
             "a background-dispatched run must not be reachable by the interrupt cascade"

      refute bg_grandchild in descendants,
             "a background run's OWN descendants must not be ripped out from under it either"
    end
  end

  describe "cancel/1 — transitive cooperative flag propagation" do
    test "cancelling the root sets the ETS cancel flag for child AND grandchild" do
      root = sid("flagroot")
      child = "agent:#{root}:1"
      grandchild = "agent:#{child}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "agent", task: "t"})

      RunStore.start_run(%{
        agent_id: grandchild,
        parent_session_id: child,
        role: "agent",
        task: "t"
      })

      Loop.cancel(root)

      assert [{^root, true}] = :ets.lookup(@cancel_table, root)
      assert [{^child, true}] = :ets.lookup(@cancel_table, child)
      assert [{^grandchild, true}] = :ets.lookup(@cancel_table, grandchild)
    end

    test "cancelling the root does NOT flag a background-dispatched descendant" do
      root = sid("flagbg")
      attached = "agent:#{root}:attached"
      bg = "agent:#{root}:bg"

      RunStore.start_run(%{agent_id: attached, parent_session_id: root, role: "agent", task: "t"})

      RunStore.start_run(%{
        agent_id: bg,
        parent_session_id: root,
        role: "background",
        task: "t",
        background: true
      })

      Loop.cancel(root)

      assert [{^root, true}] = :ets.lookup(@cancel_table, root)
      assert [{^attached, true}] = :ets.lookup(@cancel_table, attached)
      assert :ets.lookup(@cancel_table, bg) == [],
             "an interrupt must not set the cooperative cancel flag on a background run"
    end
  end

  describe "cancel/1 — background shell job cascade" do
    test "cancelling the root kills a RUNNING background shell job owned by a descendant" do
      root = sid("bgroot")
      child = "agent:#{root}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "agent", task: "t"})

      {:ok, bg_id} =
        BackgroundManager.start("sleep 5", System.tmp_dir!(), session_id: child)

      # Confirm it's actually running before we cancel, else the assertion
      # below is meaningless.
      assert {:ok, %{status: :running}} = BackgroundManager.output(bg_id)

      Loop.cancel(root)

      assert {:ok, %{status: status}} = BackgroundManager.output(bg_id)
      assert status in [:killed, :done, :failed]
    end
  end

  describe "BackgroundManager.cancel_for_sessions/1" do
    test "kills running jobs across multiple session ids in one pass" do
      s1 = sid("multi1")
      s2 = sid("multi2")

      {:ok, id1} = BackgroundManager.start("sleep 5", System.tmp_dir!(), session_id: s1)
      {:ok, id2} = BackgroundManager.start("sleep 5", System.tmp_dir!(), session_id: s2)

      killed = BackgroundManager.cancel_for_sessions([s1, s2])

      assert killed == 2
      assert {:ok, %{status: :killed}} = BackgroundManager.output(id1)
      assert {:ok, %{status: :killed}} = BackgroundManager.output(id2)
    end

    test "returns 0 when no running job matches the given sessions" do
      assert BackgroundManager.cancel_for_sessions([sid("nomatch")]) == 0
    end
  end
end
