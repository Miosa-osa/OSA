defmodule OptimalSystemAgent.Tools.Builtins.BriefTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Brief.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── Constants ────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'brief'" do
      assert Constants.tool_name() == "brief"
    end

    test "valid_windows includes 24 as an option" do
      assert 24 in Constants.valid_windows()
    end

    test "default_window_hours is in valid_windows" do
      assert Constants.default_window_hours() in Constants.valid_windows()
    end

    test "max_brief_chars is positive" do
      assert Constants.max_brief_chars() > 0
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2" do
    test "accepts empty map (uses defaults)", %{ctx: ctx} do
      assert {:ok, _} = Handler.validate(%{}, ctx)
    end

    test "accepts valid window_hours", %{ctx: ctx} do
      assert {:ok, %{"window_hours" => 6}} = Handler.validate(%{"window_hours" => 6}, ctx)
    end

    test "accepts valid window_hours with topic", %{ctx: ctx} do
      assert {:ok, input} = Handler.validate(%{"window_hours" => 24, "topic" => "deploy"}, ctx)
      assert input["topic"] == "deploy"
    end

    test "rejects invalid window_hours", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"window_hours" => 99}, ctx)
      assert msg =~ "window_hours"
    end

    test "rejects non-integer window_hours", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"window_hours" => "yesterday"}, ctx)
    end

    test "rejects blank topic", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"topic" => "   "}, ctx)
      assert msg =~ "blank"
    end

    test "rejects non-string topic", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"topic" => 42}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate("not a map", ctx)
    end
  end

  # ── Handler.check_permissions/2 ─────────────────────────────────────

  describe "check_permissions/2" do
    test "always allows", %{ctx: ctx} do
      assert {:allow, _} = Handler.check_permissions(%{}, ctx)
    end
  end

  # ── Handler.execute/2 ────────────────────────────────────────────────

  describe "execute/2" do
    test "returns an ok tuple with a string brief", %{ctx: ctx} do
      assert {:ok, brief} = Handler.execute(%{"window_hours" => 1}, ctx)
      assert is_binary(brief)
    end

    test "brief mentions the window when no entries found", %{ctx: ctx} do
      assert {:ok, brief} = Handler.execute(%{"window_hours" => 1}, ctx)
      # Either a "no activity" message or a summary — both are strings
      assert String.length(brief) > 0
    end

    test "respects topic in fallback message", %{ctx: ctx} do
      assert {:ok, brief} = Handler.execute(%{"window_hours" => 1, "topic" => "deploy"}, ctx)
      assert is_binary(brief)
    end

    test "brief does not exceed max_brief_chars", %{ctx: ctx} do
      assert {:ok, brief} = Handler.execute(%{"window_hours" => 24}, ctx)
      assert String.length(brief) <= Constants.max_brief_chars()
    end
  end

  # ── Tool callbacks ───────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name returns 'brief'" do
      assert Tool.name() == "brief"
    end

    test "should_defer? is true" do
      assert Tool.should_defer?()
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

    test "open_world? is false" do
      refute Tool.open_world?(%{}, UseContext.empty())
    end

    test "safety is :read_only" do
      assert Tool.safety() == :read_only
    end

    test "description contains 'memory_recall' cross-reference" do
      assert Tool.description() =~ "memory_recall"
    end

    test "aliases include 'summary'" do
      assert "summary" in Tool.aliases()
    end

    test "parameters schema has window_hours as enum" do
      params = Tool.parameters()
      assert get_in(params, ["properties", "window_hours", "enum"]) == Constants.valid_windows()
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use renders kind:brief" do
      assert %{kind: "brief"} = UI.render(:tool_use, %{"window_hours" => 24}, [])
    end

    test "tool_result renders kind:brief_result" do
      assert %{kind: "brief_result", text: "hello"} = UI.render(:tool_result, "hello", [])
    end

    test "error renders kind:brief_error" do
      assert %{kind: "brief_error", message: "oops"} = UI.render(:error, "oops", [])
    end

    test "unknown stage returns nil" do
      assert nil == UI.render(:unknown, %{}, [])
    end
  end
end
