defmodule OptimalSystemAgent.Tools.Builtins.RemoteTriggerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.RemoteTrigger.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  describe "validate/2" do
    test "accepts valid create action", %{ctx: ctx} do
      input = %{"action" => "create", "type" => "webhook"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts valid list action", %{ctx: ctx} do
      input = %{"action" => "list"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts valid fire action with trigger_id", %{ctx: ctx} do
      input = %{"action" => "fire", "trigger_id" => "abc123"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts valid remove action with trigger_id", %{ctx: ctx} do
      input = %{"action" => "remove", "trigger_id" => "abc123"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "rejects unknown action", %{ctx: ctx} do
      input = %{"action" => "telepathy"}
      assert {:error, msg, -32_602} = Handler.validate(input, ctx)
      assert msg =~ "action must be"
    end

    test "rejects fire without trigger_id", %{ctx: ctx} do
      assert {:error, _msg, -32_602} = Handler.validate(%{"action" => "fire"}, ctx)
    end

    test "rejects remove without trigger_id", %{ctx: ctx} do
      assert {:error, _msg, -32_602} = Handler.validate(%{"action" => "remove"}, ctx)
    end

    test "rejects create without type", %{ctx: ctx} do
      assert {:error, _msg, -32_602} = Handler.validate(%{"action" => "create"}, ctx)
    end

    test "rejects missing action key", %{ctx: ctx} do
      assert {:error, _msg, -32_602} = Handler.validate(%{}, ctx)
    end
  end

  describe "Tool callbacks" do
    test "tool name and metadata" do
      assert Tool.name() == "remote_trigger"
      assert "trigger" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
      refute Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only? differentiates by action" do
      assert Tool.read_only?(%{"action" => "list"}, UseContext.empty())
      refute Tool.read_only?(%{"action" => "fire"}, UseContext.empty())
      refute Tool.read_only?(%{"action" => "create"}, UseContext.empty())
      refute Tool.read_only?(%{"action" => "remove"}, UseContext.empty())
    end

    test "destructive? only for remove" do
      assert Tool.destructive?(%{"action" => "remove"}, UseContext.empty())
      refute Tool.destructive?(%{"action" => "list"}, UseContext.empty())
      refute Tool.destructive?(%{"action" => "fire"}, UseContext.empty())
      refute Tool.destructive?(%{"action" => "create"}, UseContext.empty())
    end
  end
end
