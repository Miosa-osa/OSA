defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQueryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.CrossTeamQuery
  alias OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ──────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'cross_team_query'" do
      assert Constants.tool_name() == "cross_team_query"
    end

    test "actions/0 returns the four valid actions" do
      assert Constants.actions() == ["ask", "poll", "answer", "list"]
    end

    test "peer_queries_table/0 returns an atom" do
      table = Constants.peer_queries_table()
      assert is_atom(table)
    end
  end

  # ── Shim surface ───────────────────────────────────────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert CrossTeamQuery.name() == "cross_team_query"
    end

    test "description/0 returns a non-empty string" do
      desc = CrossTeamQuery.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 requires action" do
      params = CrossTeamQuery.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
    end

    test "should_defer?/0 is true" do
      assert CrossTeamQuery.should_defer?() == true
    end

    test "safety/0 is :read_only" do
      assert CrossTeamQuery.safety() == :read_only
    end

    test "read_only?/2 is true" do
      assert CrossTeamQuery.read_only?(%{}, UseContext.empty())
    end

    test "concurrency_safe?/2 is true" do
      assert CrossTeamQuery.concurrency_safe?(%{}, UseContext.empty())
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────────

  describe "Tool" do
    test "is structured? (exports execute/2)" do
      assert function_exported?(Tool, :execute, 2)
    end

    test "name/0 returns 'cross_team_query'" do
      assert Tool.name() == "cross_team_query"
    end

    test "should_defer?/0 is true" do
      assert Tool.should_defer?() == true
    end

    test "read_only?/2 is true" do
      assert Tool.read_only?(%{}, UseContext.empty())
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "safety/0 is :read_only" do
      assert Tool.safety() == :read_only
    end
  end

  # ── Handler: validate ─────────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid 'ask' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "ask"}, UseContext.empty())
    end

    test "accepts valid 'poll' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "poll"}, UseContext.empty())
    end

    test "accepts valid 'answer' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "answer"}, UseContext.empty())
    end

    test "accepts valid 'list' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "list"}, UseContext.empty())
    end

    test "rejects unknown action" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "broadcast"}, UseContext.empty())

      assert msg =~ "Invalid action"
    end

    test "rejects missing action" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "Missing required parameter"
    end
  end

  # ── Handler: check_permissions ────────────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "allows normal context" do
      assert {:allow, _} =
               Handler.check_permissions(%{"action" => "ask"}, UseContext.empty())
    end

    test "allows read-only context (tool is read-only)" do
      ctx = %{UseContext.empty() | read_only_request?: true}
      assert {:allow, _} = Handler.check_permissions(%{"action" => "ask"}, ctx)
    end
  end

  # ── Handler: execute — list action with missing ETS table ─────────────────

  describe "Handler.execute/2 — list graceful degradation" do
    test "list returns empty when ETS table does not exist" do
      ctx = %{UseContext.empty() | session_id: "team-abc"}

      assert {:ok, msg} =
               Handler.execute(%{"action" => "list", "team_id" => "team-abc"}, ctx)

      # Should not crash — ETS rescue returns empty list
      assert msg =~ "team-abc"
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "contains action descriptions" do
      prompt = Prompt.render([])
      assert prompt =~ "ask"
      assert prompt =~ "poll"
      assert prompt =~ "answer"
    end

    test "mentions read-only nature" do
      prompt = Prompt.render([])
      assert prompt =~ "read-only" or prompt =~ "information"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind 'cross_team_query'" do
      result =
        UI.render(:tool_use, %{"action" => "ask", "target_team" => "backend"}, [])

      assert result[:kind] == "cross_team_query"
      assert result[:action] == "ask"
    end

    test ":tool_result returns kind 'cross_team_query_result'" do
      result = UI.render(:tool_result, "Answer received.", [])
      assert result[:kind] == "cross_team_query_result"
    end

    test ":error returns kind 'cross_team_query_error'" do
      result = UI.render(:error, "not found", [])
      assert result[:kind] == "cross_team_query_error"
      assert result[:message] == "not found"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, nil, []) == nil
    end
  end
end
