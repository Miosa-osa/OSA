defmodule OptimalSystemAgent.Tools.Builtins.SleepTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Sleep.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  describe "validate/2" do
    test "accepts valid seconds", %{ctx: ctx} do
      assert {:ok, %{"seconds" => 5}} = Handler.validate(%{"seconds" => 5}, ctx)
    end

    test "rejects negative seconds", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"seconds" => -1}, ctx)
    end

    test "rejects non-integer seconds", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"seconds" => "five"}, ctx)
    end

    test "rejects missing seconds", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{}, ctx)
    end

    test "rejects seconds over max", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"seconds" => 7200}, ctx)
      assert msg =~ "must be"
    end
  end

  describe "execute/2" do
    test "sleeps for the requested duration (short)", %{ctx: ctx} do
      started = System.monotonic_time(:millisecond)
      assert {:ok, msg} = Handler.execute(%{"seconds" => 1}, ctx)
      elapsed = System.monotonic_time(:millisecond) - started

      assert msg =~ "Slept for"
      assert elapsed >= 900
      assert elapsed < 1500
    end
  end

  describe "Tool callbacks" do
    test "tool name and metadata" do
      assert Tool.name() == "sleep"
      assert "wait" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
      assert Tool.read_only?(%{}, UseContext.empty())
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end
  end
end
