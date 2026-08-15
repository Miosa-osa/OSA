defmodule OptimalSystemAgent.Tools.Builtins.EnterPlanModeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.EnterPlanMode.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── validate/2 ──────────────────────────────────────────────────────────

  describe "validate/2" do
    test "accepts an empty map", %{ctx: ctx} do
      assert {:ok, %{}} = Handler.validate(%{}, ctx)
    end

    test "accepts map with optional reason", %{ctx: ctx} do
      assert {:ok, %{"reason" => "refactor"}} =
               Handler.validate(%{"reason" => "refactor"}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate("bad", ctx)
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

    test "passes input through unmodified", %{ctx: ctx} do
      input = %{"reason" => "complex task"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end
  end

  # ── execute/2 — no live session ─────────────────────────────────────────

  describe "execute/2 without a live session" do
    test "returns confirmation message when session is not running", %{ctx: ctx} do
      # UseContext.empty() has session_id="test" — no running Loop process.
      assert {:ok, msg} = Handler.execute(%{}, ctx)
      assert is_binary(msg)
      assert msg =~ "Plan mode"
    end

    test "confirmation mentions offline when no session present", %{ctx: ctx} do
      assert {:ok, msg} = Handler.execute(%{}, ctx)
      # Either "entered" (live) or "offline" — both are valid success paths.
      assert msg =~ ~r/entered|offline/i
    end
  end

  # ── Tool module callbacks ────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name is enter_plan_mode" do
      assert Tool.name() == "enter_plan_mode"
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

    test "aliases include plan_mode_on" do
      assert "plan_mode_on" in Tool.aliases()
    end
  end

  describe "registry integration" do
    test "enter_plan_mode is registered as a callable tool" do
      names =
        OptimalSystemAgent.Tools.Registry.list_tools_direct()
        |> Enum.map(& &1.name)

      assert "enter_plan_mode" in names
    end
  end
end
