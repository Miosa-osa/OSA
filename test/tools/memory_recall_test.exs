defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecallTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MemoryRecall.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session"}

  # ── Constants ─────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns memory_recall" do
      assert Constants.tool_name() == "memory_recall"
    end

    test "default_limit/0 returns 10" do
      assert Constants.default_limit() == 10
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

    test "references memory_save by its live tool name" do
      result = Prompt.render([])
      save_name = OptimalSystemAgent.Tools.Builtins.MemorySave.Constants.tool_name()
      assert String.contains?(result, save_name)
    end

    test "mentions session start use case" do
      result = Prompt.render([])
      assert String.contains?(result, "session start")
    end
  end

  # ── Tool identity & semantics ─────────────────────────────────────────

  describe "Tool identity" do
    test "name/0 returns memory_recall" do
      assert Tool.name() == "memory_recall"
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

    test "concurrency_safe?/2 is true (read-only)" do
      assert Tool.concurrency_safe?(%{}, @ctx) == true
    end

    test "read_only?/2 is true" do
      assert Tool.read_only?(%{}, @ctx) == true
    end

    test "destructive?/2 is false" do
      assert Tool.destructive?(%{}, @ctx) == false
    end

    test "safety/0 returns :read_only" do
      assert Tool.safety() == :read_only
    end
  end

  # ── Handler.validate/2 ────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid query-only input" do
      assert {:ok, %{"query" => "elixir"}} =
               Handler.validate(%{"query" => "elixir"}, @ctx)
    end

    test "accepts query with valid category" do
      assert {:ok, _} =
               Handler.validate(%{"query" => "arch", "category" => "decision"}, @ctx)
    end

    test "accepts query with valid limit" do
      assert {:ok, _} =
               Handler.validate(%{"query" => "arch", "limit" => 5}, @ctx)
    end

    test "rejects invalid category" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"query" => "arch", "category" => "bad"}, @ctx)

      assert String.contains?(msg, "Invalid category")
    end

    test "rejects non-positive limit" do
      assert {:error, _, -32_602} =
               Handler.validate(%{"query" => "arch", "limit" => 0}, @ctx)
    end

    test "rejects negative limit" do
      assert {:error, _, -32_602} =
               Handler.validate(%{"query" => "arch", "limit" => -1}, @ctx)
    end

    test "rejects non-integer limit" do
      assert {:error, _, -32_602} =
               Handler.validate(%{"query" => "arch", "limit" => "ten"}, @ctx)
    end

    test "rejects empty query" do
      assert {:error, _, -32_602} = Handler.validate(%{"query" => ""}, @ctx)
    end

    test "rejects non-string query" do
      assert {:error, _, -32_602} = Handler.validate(%{"query" => 42}, @ctx)
    end

    test "rejects missing query" do
      assert {:error, "Missing required parameter: query", -32_602} =
               Handler.validate(%{}, @ctx)
    end

    test "accepts all valid categories" do
      for cat <- Constants.valid_categories() do
        assert {:ok, _} =
                 Handler.validate(%{"query" => "test", "category" => cat}, @ctx)
      end
    end
  end

  # ── Handler.check_permissions/2 ──────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "always allows" do
      input = %{"query" => "test"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end
  end

  # ── UI.render/3 ──────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind=memory_recall with query" do
      result = UI.render(:tool_use, %{"query" => "elixir patterns"}, [])
      assert result.kind == "memory_recall"
      assert result.query == "elixir patterns"
    end

    test ":tool_result with found memories extracts count" do
      result = UI.render(:tool_result, "Found 3 memories\n---\n1. foo", [])
      assert result.kind == "memory_recall_result"
      assert result.count == 3
    end

    test ":tool_result with no memories has count 0" do
      result = UI.render(:tool_result, "No memories found for: foo", [])
      assert result.kind == "memory_recall_result"
      assert result.count == 0
    end

    test ":rejected returns kind=memory_recall_rejected" do
      result = UI.render(:rejected, %{}, [])
      assert result.kind == "memory_recall_rejected"
    end

    test ":error returns kind=memory_recall_error with message" do
      result = UI.render(:error, "db error", [])
      assert result.kind == "memory_recall_error"
      assert result.message == "db error"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, %{}, []) == nil
    end
  end

  # ── Shim parity ───────────────────────────────────────────────────────

  describe "MemoryRecall shim delegates to Tool" do
    alias OptimalSystemAgent.Tools.Builtins.MemoryRecall

    test "name/0 matches Tool.name/0" do
      assert MemoryRecall.name() == Tool.name()
    end

    test "always_load?/0 matches Tool.always_load?/0" do
      assert MemoryRecall.always_load?() == Tool.always_load?()
    end

    test "safety/0 matches Tool.safety/0" do
      assert MemoryRecall.safety() == Tool.safety()
    end

    test "execute/2 exists on shim (structured layout)" do
      assert function_exported?(MemoryRecall, :execute, 2)
    end

    test "read_only?/2 is true via shim" do
      assert MemoryRecall.read_only?(%{}, @ctx) == true
    end

    test "concurrency_safe?/2 is true via shim" do
      assert MemoryRecall.concurrency_safe?(%{}, @ctx) == true
    end
  end
end
