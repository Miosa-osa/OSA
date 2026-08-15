defmodule OptimalSystemAgent.Tools.Builtins.MonitorTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Monitor.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  describe "validate/2" do
    test "accepts valid file kind", %{ctx: ctx} do
      input = %{"kind" => "file", "target" => "/tmp/foo"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "rejects unknown kind", %{ctx: ctx} do
      input = %{"kind" => "telepathy", "target" => "/tmp/foo"}
      assert {:error, msg, -32_602} = Handler.validate(input, ctx)
      assert msg =~ "kind must be"
    end

    test "rejects empty target", %{ctx: ctx} do
      input = %{"kind" => "file", "target" => ""}
      assert {:error, _msg, -32_602} = Handler.validate(input, ctx)
    end

    test "rejects missing fields", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{}, ctx)
      assert {:error, _, -32_602} = Handler.validate(%{"kind" => "file"}, ctx)
    end

    test "rejects out-of-range duration", %{ctx: ctx} do
      input = %{"kind" => "file", "target" => "/tmp/x", "duration_seconds" => 99_999}
      assert {:error, msg, -32_602} = Handler.validate(input, ctx)
      assert msg =~ "duration_seconds"
    end

    test "accepts duration within range", %{ctx: ctx} do
      input = %{"kind" => "file", "target" => "/tmp/x", "duration_seconds" => 30}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end
  end

  describe "check_permissions/2" do
    test "denies non-http URL", %{ctx: ctx} do
      input = %{"kind" => "url", "target" => "ftp://example.com/x"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx)
      assert msg =~ "Access denied"
    end

    test "allows https URL", %{ctx: ctx} do
      input = %{"kind" => "url", "target" => "https://example.com/x"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end

    test "allows file kind unconditionally", %{ctx: ctx} do
      input = %{"kind" => "file", "target" => "/tmp/x"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end
  end

  describe "Tool callbacks" do
    test "tool name and metadata" do
      assert Tool.name() == "monitor"
      assert "watch" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
      assert Tool.read_only?(%{}, UseContext.empty())
      refute Tool.destructive?(%{}, UseContext.empty())
      assert Tool.open_world?(%{"kind" => "url"}, UseContext.empty())
      refute Tool.open_world?(%{"kind" => "file"}, UseContext.empty())
    end
  end
end
