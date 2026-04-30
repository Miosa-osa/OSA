defmodule OptimalSystemAgent.Tools.Builtins.MemorySaveTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MemorySave.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session"}

  # ── Constants ─────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns memory_save" do
      assert Constants.tool_name() == "memory_save"
    end

    test "valid_categories/0 includes all expected categories" do
      cats = Constants.valid_categories()
      assert "decision" in cats
      assert "preference" in cats
      assert "pattern" in cats
      assert "lesson" in cats
      assert "context" in cats
      assert "project" in cats
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "returns a non-empty string" do
      result = Prompt.render([])
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "references memory_recall by its live tool name" do
      result = Prompt.render([])
      recall_name = OptimalSystemAgent.Tools.Builtins.MemoryRecall.Constants.tool_name()
      assert String.contains?(result, recall_name)
    end

    test "contains the Iron Rule" do
      result = Prompt.render([])
      assert String.contains?(result, "Iron Rule")
    end
  end

  # ── Tool identity & semantics ─────────────────────────────────────────

  describe "Tool identity" do
    test "name/0 returns memory_save" do
      assert Tool.name() == "memory_save"
    end

    test "name/0 matches Constants.tool_name/0" do
      assert Tool.name() == Constants.tool_name()
    end

    test "always_load?/0 is true" do
      assert Tool.always_load?() == true
    end

    test "should_defer?/0 is false" do
      assert Tool.should_defer?() == false
    end

    test "concurrency_safe?/2 is false (shared write)" do
      assert Tool.concurrency_safe?(%{}, @ctx) == false
    end

    test "read_only?/2 is false" do
      assert Tool.read_only?(%{}, @ctx) == false
    end

    test "destructive?/2 is false (additive saves)" do
      assert Tool.destructive?(%{}, @ctx) == false
    end

    test "safety/0 returns :write_safe" do
      assert Tool.safety() == :write_safe
    end
  end

  # ── Handler.validate/2 ────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid content-only input" do
      assert {:ok, %{"content" => "hello"}} =
               Handler.validate(%{"content" => "hello"}, @ctx)
    end

    test "accepts content with valid category" do
      assert {:ok, _} =
               Handler.validate(%{"content" => "data", "category" => "decision"}, @ctx)
    end

    test "rejects invalid category" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"content" => "data", "category" => "invalid"}, @ctx)

      assert String.contains?(msg, "Invalid category")
    end

    test "rejects empty content" do
      assert {:error, _, -32_602} = Handler.validate(%{"content" => ""}, @ctx)
    end

    test "rejects non-string content" do
      assert {:error, _, -32_602} = Handler.validate(%{"content" => 42}, @ctx)
    end

    test "rejects missing content" do
      assert {:error, "Missing required parameter: content", -32_602} =
               Handler.validate(%{}, @ctx)
    end

    test "accepts all valid categories" do
      for cat <- Constants.valid_categories() do
        assert {:ok, _} =
                 Handler.validate(%{"content" => "test", "category" => cat}, @ctx)
      end
    end
  end

  # ── Handler.check_permissions/2 ──────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"content" => "test"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end
  end

  # ── UI.render/3 ──────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind=memory_save with content preview" do
      result = UI.render(:tool_use, %{"content" => "hello world"}, [])
      assert result.kind == "memory_save"
      assert result.content_preview == "hello world"
    end

    test ":tool_use truncates long content to 120 chars" do
      long = String.duplicate("x", 200)
      result = UI.render(:tool_use, %{"content" => long}, [])
      assert String.length(result.content_preview) == 120
    end

    test ":tool_result returns kind=memory_save_result" do
      result = UI.render(:tool_result, "Saved · decision (global)", [])
      assert result.kind == "memory_save_result"
      assert result.message == "Saved · decision (global)"
    end

    test ":rejected returns kind=memory_save_rejected" do
      result = UI.render(:rejected, %{}, [])
      assert result.kind == "memory_save_rejected"
    end

    test ":error returns kind=memory_save_error with message" do
      result = UI.render(:error, "oops", [])
      assert result.kind == "memory_save_error"
      assert result.message == "oops"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, %{}, []) == nil
    end
  end

  # ── Shim parity ───────────────────────────────────────────────────────

  describe "MemorySave shim delegates to Tool" do
    alias OptimalSystemAgent.Tools.Builtins.MemorySave

    test "name/0 matches Tool.name/0" do
      assert MemorySave.name() == Tool.name()
    end

    test "always_load?/0 matches Tool.always_load?/0" do
      assert MemorySave.always_load?() == Tool.always_load?()
    end

    test "safety/0 matches Tool.safety/0" do
      assert MemorySave.safety() == Tool.safety()
    end

    test "execute/2 exists on shim (structured layout)" do
      Code.ensure_loaded!(MemorySave)
      assert function_exported?(MemorySave, :execute, 2)
    end
  end
end
