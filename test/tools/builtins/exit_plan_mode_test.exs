defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanModeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ExitPlanMode.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.PlanStore

  setup do
    on_exit(fn -> File.rm(PlanStore.plan_file_path("test")) end)
    {:ok, ctx: UseContext.empty()}
  end

  # ── validate/2 ──────────────────────────────────────────────────────────

  describe "validate/2" do
    test "accepts an empty map", %{ctx: ctx} do
      assert {:ok, %{}} = Handler.validate(%{}, ctx)
    end

    test "accepts a map with a string plan", %{ctx: ctx} do
      assert {:ok, %{"plan" => "step 1, step 2"}} =
               Handler.validate(%{"plan" => "step 1, step 2"}, ctx)
    end

    test "rejects a non-string plan value", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"plan" => 42}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate("oops", ctx)
    end

    test "rejects nil input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(nil, ctx)
    end
  end

  # ── check_permissions/2 ─────────────────────────────────────────────────

  describe "check_permissions/2" do
    test "always allows", %{ctx: ctx} do
      assert {:allow, _} = Handler.check_permissions(%{}, ctx)
    end

    test "passes input through unmodified with plan present", %{ctx: ctx} do
      input = %{"plan" => "deploy the changes"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end
  end

  # ── execute/2 — no live session ─────────────────────────────────────────

  describe "execute/2 without a live session" do
    test "returns error when session is not running", %{ctx: ctx} do
      assert {:error, _msg} = Handler.execute(%{}, ctx)
    end

    test "echoes plan summary in response when plan provided", %{ctx: ctx} do
      plan = "1. read files 2. apply patch 3. run tests"
      assert {:ok, msg} = Handler.execute(%{"plan" => plan}, ctx)
      assert msg =~ plan
    end

    test "response without plan does not claim mode changed", %{ctx: ctx} do
      assert {:error, msg} = Handler.execute(%{}, ctx)
      assert msg =~ "Cannot exit plan mode"
    end

    test "response is always a binary string", %{ctx: ctx} do
      assert {:error, msg} = Handler.execute(%{}, ctx)
      assert is_binary(msg)
    end
  end

  # ── Tool module callbacks ────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name is exit_plan_mode" do
      assert Tool.name() == "exit_plan_mode"
    end

    test "always_load? is true" do
      assert Tool.always_load?()
    end

    test "should_defer? is false" do
      refute Tool.should_defer?()
    end

    test "read_only? is true" do
      assert Tool.read_only?(%{}, UseContext.empty())
    end

    test "concurrency_safe? is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "destructive? is false" do
      refute Tool.destructive?(%{}, UseContext.empty())
    end

    test "safety is :read_only" do
      assert Tool.safety() == :read_only
    end

    test "parameters schema has no required fields" do
      params = Tool.parameters()
      assert Map.get(params, "required") == []
    end

    test "aliases include plan_mode_off" do
      assert "plan_mode_off" in Tool.aliases()
    end
  end

  describe "registry integration" do
    test "exit_plan_mode is registered as a callable tool" do
      names =
        OptimalSystemAgent.Tools.Registry.list_tools_direct()
        |> Enum.map(& &1.name)

      assert "exit_plan_mode" in names
    end
  end

  # ── Model-invoked plan transitions route into the PlanStore approval
  #    round-trip (gap #3) ───────────────────────────────────────────────
  describe "execute/2 with a plan — routes into the PlanStore approval round-trip" do
    setup do
      session_id = "exit-plan-mode-test-#{System.unique_integer([:positive, :monotonic])}"
      on_exit(fn -> File.rm(PlanStore.plan_file_path(session_id)) end)
      {:ok, ctx: %{UseContext.empty() | session_id: session_id}, session_id: session_id}
    end

    test "writes the plan to the durable plan file", %{ctx: ctx, session_id: session_id} do
      plan = "### Goal\nRefactor the widget factory.\n"
      assert {:ok, _msg} = Handler.execute(%{"plan" => plan}, ctx)

      assert {:ok, ^plan} = PlanStore.read_plan_file(session_id)
    end

    test "indexes a pending approval readable via PlanStore.get/1", %{
      ctx: ctx,
      session_id: session_id
    } do
      plan = "### Goal\nAdd rate limiting.\n"
      Handler.execute(%{"plan" => plan}, ctx)

      assert %{plan: ^plan} = PlanStore.get(session_id)
    end

    test "calling exit_plan_mode WITHOUT a plan does not stash anything in PlanStore", %{
      ctx: ctx,
      session_id: session_id
    } do
      Handler.execute(%{}, ctx)

      assert PlanStore.get(session_id) == nil
      assert PlanStore.read_plan_file(session_id) == {:error, :not_found}
    end

    test "confirmation message mentions approval, not immediate execution", %{ctx: ctx} do
      plan = "### Goal\nDo it.\n"
      assert {:ok, msg} = Handler.execute(%{"plan" => plan}, ctx)
      assert msg =~ ~r/approv/i
    end
  end
end
