defmodule OptimalSystemAgent.Agent.PlanStoreTest do
  @moduledoc """
  `Agent.PlanStore` durability tests: the plan TEXT is written to a real file
  (source of truth), re-readable across "resets" (a fresh `get/1` call has no
  in-memory cache to go stale), and survives `take/1` (approval) since the
  file is deliberately kept on disk as a durable record.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.PlanStore

  defp unique_session, do: "plan-store-test-#{:erlang.unique_integer([:positive, :monotonic])}"

  setup do
    session_id = unique_session()
    on_exit(fn -> File.rm(PlanStore.plan_file_path(session_id)) end)
    {:ok, session_id: session_id}
  end

  describe "plan_file_path/1" do
    test "lives alongside the progress ledger's sessions dir", %{session_id: session_id} do
      plan_path = PlanStore.plan_file_path(session_id)
      ledger_path = OptimalSystemAgent.Agent.ProgressLedger.path(session_id)

      assert Path.dirname(plan_path) == Path.dirname(ledger_path)
      assert String.ends_with?(plan_path, ".plan.md")
    end
  end

  describe "write_plan_file/2 + read_plan_file/1" do
    test "writes and re-reads the plan text", %{session_id: session_id} do
      assert :ok = PlanStore.write_plan_file(session_id, "### Goal\nDo the thing.\n")
      assert {:ok, "### Goal\nDo the thing.\n"} = PlanStore.read_plan_file(session_id)
    end

    test "read returns :not_found when no plan file exists yet", %{session_id: session_id} do
      assert {:error, :not_found} = PlanStore.read_plan_file(session_id)
    end

    test "a second write replaces the plan text (incremental editing)", %{session_id: session_id} do
      PlanStore.write_plan_file(session_id, "draft v1")
      PlanStore.write_plan_file(session_id, "draft v2 — revised")

      assert {:ok, "draft v2 — revised"} = PlanStore.read_plan_file(session_id)
    end
  end

  describe "put/3 + get/1 — pending approval index backed by the file" do
    test "put writes the plan file and indexes the pending approval", %{session_id: session_id} do
      :ok = PlanStore.put(session_id, "### Goal\nShip it.\n", "please ship it")

      assert %{plan: plan, input: "please ship it"} = PlanStore.get(session_id)
      assert plan == "### Goal\nShip it.\n"
      assert {:ok, ^plan} = PlanStore.read_plan_file(session_id)
    end

    test "get reads the plan live from disk, not a stale ETS copy", %{session_id: session_id} do
      PlanStore.put(session_id, "original plan", "input")

      # Out-of-band edit directly to the file (simulating a resumed
      # investigative plan-mode turn revising its own draft).
      PlanStore.write_plan_file(session_id, "revised plan")

      assert %{plan: "revised plan"} = PlanStore.get(session_id)
    end

    test "get returns nil when nothing is pending", %{session_id: session_id} do
      assert PlanStore.get(session_id) == nil
    end
  end

  describe "take/1 — approval round-trip" do
    test "take returns the pending plan and clears the pending marker", %{session_id: session_id} do
      PlanStore.put(session_id, "plan text", "input text")

      assert %{plan: "plan text", input: "input text"} = PlanStore.take(session_id)
      assert PlanStore.get(session_id) == nil
    end

    test "take does NOT delete the durable plan file — it stays as a record", %{
      session_id: session_id
    } do
      PlanStore.put(session_id, "plan text", "input text")
      PlanStore.take(session_id)

      assert {:ok, "plan text"} = PlanStore.read_plan_file(session_id)
    end

    test "take returns nil when nothing is pending", %{session_id: session_id} do
      assert PlanStore.take(session_id) == nil
    end
  end

  describe "clear/1" do
    test "clears the pending marker but keeps the plan file", %{session_id: session_id} do
      PlanStore.put(session_id, "plan text", "input text")
      PlanStore.clear(session_id)

      assert PlanStore.get(session_id) == nil
      assert {:ok, "plan text"} = PlanStore.read_plan_file(session_id)
    end
  end
end
