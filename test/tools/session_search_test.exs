defmodule OptimalSystemAgent.Tools.Builtins.SessionSearchTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.SessionSearch
  alias OptimalSystemAgent.Tools.Builtins.SessionSearch.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session-search"}

  # ── Shim identity ────────────────────────────────────────────────────

  describe "name/0" do
    test "returns session_search" do
      assert SessionSearch.name() == "session_search"
    end

    test "matches Constants.tool_name/0" do
      assert SessionSearch.name() == Constants.tool_name()
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = SessionSearch.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns valid JSON Schema" do
      params = SessionSearch.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "query" in params["required"]
    end

    test "includes limit parameter" do
      assert SessionSearch.parameters()["properties"]["limit"]["type"] == "integer"
    end
  end

  # ── Loading semantics ────────────────────────────────────────────────

  describe "should_defer?/0" do
    test "returns false" do
      refute SessionSearch.should_defer?()
    end
  end

  describe "always_load?/0" do
    test "returns true" do
      assert SessionSearch.always_load?()
    end
  end

  # ── Execution semantics ──────────────────────────────────────────────

  describe "concurrency_safe?/2" do
    test "returns true" do
      assert SessionSearch.concurrency_safe?(%{"query" => "hello"}, @ctx)
    end
  end

  describe "read_only?/2" do
    test "returns true" do
      assert SessionSearch.read_only?(%{"query" => "hello"}, @ctx)
    end
  end

  describe "destructive?/2" do
    test "returns false" do
      refute SessionSearch.destructive?(%{"query" => "hello"}, @ctx)
    end
  end

  describe "safety/0" do
    test "returns :read_only" do
      assert SessionSearch.safety() == :read_only
    end
  end

  describe "max_result_size_chars/0" do
    test "returns 50_000" do
      assert SessionSearch.max_result_size_chars() == 50_000
    end

    test "matches Constants.max_result_size_chars/0" do
      assert SessionSearch.max_result_size_chars() == Constants.max_result_size_chars()
    end
  end

  # ── Constants ────────────────────────────────────────────────────────

  describe "Constants" do
    test "default_limit is positive" do
      assert Constants.default_limit() > 0
    end

    test "content_preview_chars is positive" do
      assert Constants.content_preview_chars() > 0
    end
  end

  # ── Handler: validate ────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid query" do
      assert {:ok, _} = Handler.validate(%{"query" => "hello world"}, @ctx)
    end

    test "rejects non-string query" do
      assert {:error, msg, -32_602} = Handler.validate(%{"query" => 123}, @ctx)
      assert msg =~ "string"
    end

    test "rejects missing query" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, @ctx)
      assert msg =~ "query"
    end
  end

  # ── Handler: check_permissions ───────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "always allows" do
      assert {:allow, _} = Handler.check_permissions(%{"query" => "x"}, @ctx)
    end
  end

  # ── Handler: execute ─────────────────────────────────────────────────

  describe "Handler.execute/2" do
    test "returns no-results message when nothing found" do
      assert {:ok, msg} = Handler.execute(%{"query" => "zzz_unlikely_query_xyz_abc_999"}, @ctx)
      assert msg =~ "No past sessions found matching"
    end

    test "accepts a limit parameter" do
      assert {:ok, _} =
               Handler.execute(%{"query" => "hello", "limit" => 3}, @ctx)
    end

    test "returns error for missing query" do
      assert {:error, msg} = Handler.execute(%{}, @ctx)
      assert msg =~ "query"
    end
  end

  # ── Shim execute/1 (flat compat) ──────────────────────────────────────

  describe "execute/1" do
    test "flat signature works" do
      assert {:ok, msg} = SessionSearch.execute(%{"query" => "zzz_flat_test"})
      assert is_binary(msg)
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use stage" do
      map = UI.render(:tool_use, %{"query" => "hello", "limit" => 5}, [])
      assert map.kind == "session_search"
      assert map.query == "hello"
      assert map.limit == 5
    end

    test "tool_result stage" do
      map = UI.render(:tool_result, "Found 2 match(es):", [])
      assert map.kind == "session_search_result"
      assert map.message == "Found 2 match(es):"
    end

    test "rejected stage" do
      assert %{kind: "session_search_rejected"} = UI.render(:rejected, nil, [])
    end

    test "error stage" do
      map = UI.render(:error, "boom", [])
      assert map.kind == "session_search_error"
      assert map.message == "boom"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, nil, []) == nil
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "renders without error" do
      assert is_binary(Prompt.render([]))
    end

    test "mentions default limit" do
      assert Prompt.render([]) =~ Integer.to_string(Constants.default_limit())
    end
  end

  # ── Tool module delegates ─────────────────────────────────────────────

  describe "Tool module" do
    test "name matches shim" do
      assert Tool.name() == SessionSearch.name()
    end

    test "execute/2 delegate" do
      assert {:ok, _} = Tool.execute(%{"query" => "test"}, @ctx)
    end
  end

  # ── Structured layout (execute/2 present) ────────────────────────────

  describe "structured layout" do
    test "exports execute/2" do
      # `function_exported?/3` answers for LOADED modules only, and under
      # `mix test`'s lazy code loading whether this module is already loaded
      # depends on which tests ran before — so without the explicit load this
      # assertion fails at random in a full-suite run and passes in isolation.
      Code.ensure_loaded!(SessionSearch)
      assert function_exported?(SessionSearch, :execute, 2)
    end

    test "LegacyAdapter detects as structured" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(SessionSearch)
    end
  end
end
