defmodule OptimalSystemAgent.Agent.Loop.SpendIncompletenessTest do
  @moduledoc """
  Budget enforcement must not read "we have no bill" as "the bill was zero".

  Every unknown in OSA's spend pipeline collapsed into `0.0`: an absent spend
  sidecar, a failed tree walk, a crashed rollup. Downstream that reads as
  "plenty of budget left", so a capped run kept spawning nodes on money it could
  not account for. The rollup now carries an explicit incompleteness signal and
  the enforcement gates fail CLOSED on it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_spend_inc_#{System.unique_integer([:positive])}")
    home = Path.join(tmp, "home")
    File.mkdir_p!(home)

    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, home)

    on_exit(fn ->
      case prev_home do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      File.rm_rf(tmp)
    end)

    {:ok, root: "root_#{System.unique_integer([:positive])}"}
  end

  # A descendant WITH a persisted spend sidecar.
  defp billed_child(parent, cost) do
    id = "billed_#{System.unique_integer([:positive])}"
    RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "fleet-node", task: "t"})
    SessionPersistence.save_spend(id, %{cost_usd: cost})
    RunStore.complete(id, %{status: :completed})
    id
  end

  # A descendant that FINISHED and left no spend record at all.
  defp unbilled_finished_child(parent) do
    id = "unbilled_#{System.unique_integer([:positive])}"
    RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "fleet-node", task: "t"})
    RunStore.complete(id, %{status: :completed})
    id
  end

  # A descendant that is STILL RUNNING and has not reached its first persist
  # point. Its spend is bounded by the turn in flight — not unknown.
  defp running_child(parent) do
    id = "running_#{System.unique_integer([:positive])}"
    RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "fleet-node", task: "t"})
    id
  end

  describe "load_spend/1 distinguishes absent from zero" do
    test "a real sidecar reads as complete" do
      id = "sid_#{System.unique_integer([:positive])}"
      :ok = SessionPersistence.save_spend(id, %{cost_usd: 1.5})

      spend = SessionPersistence.load_spend(id)
      assert spend.cost_usd == 1.5
      assert spend.complete == true
    end

    test "an absent sidecar reads as INCOMPLETE, not as $0.00" do
      spend = SessionPersistence.load_spend("never_written_#{System.unique_integer([:positive])}")

      assert spend.cost_usd == 0.0
      refute spend.complete, "an absent bill was reported as a complete $0.00 bill"
    end
  end

  describe "tree_spend/1" do
    test "all descendants billed → complete", %{root: root} do
      billed_child(root, 1.0)
      billed_child(root, 2.0)

      spend = Accounting.tree_spend(%{session_id: root, session_cost_usd: 0.5})
      assert spend.usd == 3.5
      assert spend.complete
      assert spend.unknown == []
    end

    test "a FINISHED descendant with no spend record makes the bill incomplete",
         %{root: root} do
      billed_child(root, 1.0)
      ghost = unbilled_finished_child(root)

      spend = Accounting.tree_spend(%{session_id: root, session_cost_usd: 0.0})

      refute spend.complete, "a node that finished without a spend record counted as free"
      assert ghost in spend.unknown
    end

    test "a still-RUNNING descendant without a sidecar does NOT make it incomplete",
         %{root: root} do
      billed_child(root, 1.0)
      running_child(root)

      spend = Accounting.tree_spend(%{session_id: root, session_cost_usd: 0.0})

      assert spend.complete,
             "a node that simply hasn't reached its first persist point is not an unknown bill"

      assert spend.usd == 1.0
    end
  end

  describe "budget_exhausted?/1 fails CLOSED on an unknown bill" do
    test "capped + incomplete → exhausted, even though the known spend is tiny",
         %{root: root} do
      billed_child(root, 0.01)
      unbilled_finished_child(root)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 100.0}

      assert Accounting.budget_exhausted?(state),
             "an unreadable bill was treated as free and spawning was allowed to continue"
    end

    test "capped + complete + under cap → not exhausted", %{root: root} do
      billed_child(root, 0.01)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 100.0}
      refute Accounting.budget_exhausted?(state)
    end

    test "UNCAPPED + incomplete → not exhausted (nothing to enforce)", %{root: root} do
      unbilled_finished_child(root)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: nil}
      refute Accounting.budget_exhausted?(state)
    end
  end

  describe "tree_budget_remaining/1" do
    test "reports no remainder when the bill is incomplete", %{root: root} do
      unbilled_finished_child(root)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 100.0}
      assert Accounting.tree_budget_remaining(state) == 0.0
    end

    test "reports the real remainder when the bill is complete", %{root: root} do
      billed_child(root, 25.0)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 100.0}
      assert Accounting.tree_budget_remaining(state) == 75.0
    end
  end
end
