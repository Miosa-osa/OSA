defmodule OptimalSystemAgent.Tools.Builtins.TeamDeleteTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.TeamDelete.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── Constants ─────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'team_delete'" do
      assert Constants.tool_name() == "team_delete"
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2 — happy paths" do
    test "accepts a valid team_id string", %{ctx: ctx} do
      input = %{"team_id" => "abc123"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts hex-style team_id", %{ctx: ctx} do
      input = %{"team_id" => "1a2b3c4d5e6f"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end
  end

  describe "validate/2 — missing or invalid parameters" do
    test "rejects missing team_id", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx)
      assert msg =~ "team_id"
    end

    test "rejects non-string team_id", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"team_id" => 42}, ctx)
      assert msg =~ "string"
    end

    test "rejects empty team_id string", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"team_id" => ""}, ctx)
      assert msg =~ "empty"
    end

    test "rejects whitespace-only team_id", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"team_id" => "   "}, ctx)
      assert msg =~ "empty"
    end

    test "rejects nil team_id", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"team_id" => nil}, ctx)
      assert msg =~ "string"
    end
  end

  # ── Handler.check_permissions/2 ──────────────────────────────────────

  describe "check_permissions/2" do
    test "denies in read_only tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :read_only}
      assert {:deny, reason} = Handler.check_permissions(%{"team_id" => "abc"}, ctx)
      assert reason =~ "destructive"
    end

    test "denies in workspace tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :workspace}
      assert {:deny, reason} = Handler.check_permissions(%{"team_id" => "abc"}, ctx)
      assert reason =~ "destructive"
    end

    test "allows in full tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :full}
      input = %{"team_id" => "abc"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end

    test "allows in subagent tier" do
      ctx = %UseContext{UseContext.empty() | permission_tier: :subagent}
      input = %{"team_id" => "abc"}
      assert {:allow, ^input} = Handler.check_permissions(input, ctx)
    end

    test "allows when permission_tier is nil (no tier set)" do
      ctx = UseContext.empty()
      # empty() sets :read_only — this reflects the fail-closed default
      assert {:deny, _} = Handler.check_permissions(%{"team_id" => "abc"}, ctx)
    end
  end

  # ── Team lifecycle integration (requires running Teams.Supervisor) ────

  describe "execute/2 integration" do
    @tag :integration
    test "dissolves a real team" do
      # Create a team so we have something to delete
      {:ok, meta} =
        OptimalSystemAgent.Teams.Manager.create_team(%{name: "test-delete-team"})

      team_id = meta.team_id
      ctx_full = %UseContext{UseContext.empty() | permission_tier: :full}

      assert {:ok, msg} = Handler.execute(%{"team_id" => team_id}, ctx_full)
      assert msg =~ team_id
      assert msg =~ "dissolved"

      # Confirm the team is gone
      refute OptimalSystemAgent.Teams.Manager.team_alive?(team_id)
    end

    @tag :integration
    test "is idempotent for a non-existent team_id" do
      ctx_full = %UseContext{UseContext.empty() | permission_tier: :full}
      assert {:ok, msg} = Handler.execute(%{"team_id" => "nonexistent-team-xyz"}, ctx_full)
      assert msg =~ "not found" or msg =~ "nothing"
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name and identity" do
      assert Tool.name() == "team_delete"
      assert "delete_team" in Tool.aliases()
      assert "dissolve_team" in Tool.aliases()
      assert Tool.search_hint() != ""
    end

    test "loading semantics" do
      assert Tool.should_defer?()
      refute Tool.always_load?()
    end

    test "execution semantics" do
      ctx = UseContext.empty()
      refute Tool.concurrency_safe?(%{}, ctx)
      refute Tool.read_only?(%{}, ctx)
      assert Tool.destructive?(%{}, ctx)
      refute Tool.open_world?(%{}, ctx)
    end

    test "parameters schema has required team_id" do
      params = Tool.parameters()
      assert params["type"] == "object"
      assert "team_id" in params["required"]
      assert Map.has_key?(params["properties"], "team_id")
    end

    test "delegates pipeline to Handler" do
      ctx = UseContext.empty()
      assert {:error, _, -32_602} = Tool.validate_input(%{}, ctx)
    end

    test "to_classifier_input extracts team_id" do
      assert Tool.to_classifier_input(%{"team_id" => "abc"}) == %{team_id: "abc"}
    end

    test "to_classifier_input returns empty string for bad input" do
      assert Tool.to_classifier_input(%{}) == ""
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use stage" do
      result = UI.render(:tool_use, %{"team_id" => "abc123"}, [])
      assert result.kind == "team_delete"
      assert result.team_id == "abc123"
    end

    test "tool_result stage" do
      result = UI.render(:tool_result, "Team abc dissolved.", [])
      assert result.kind == "team_delete_result"
      assert result.message =~ "abc"
    end

    test "error stage" do
      result = UI.render(:error, "failed to dissolve", [])
      assert result.kind == "team_delete_error"
    end

    test "rejected stage" do
      result = UI.render(:rejected, "not permitted", [])
      assert result.kind == "team_delete_rejected"
    end

    test "unknown stage returns nil" do
      assert UI.render(:progress, %{}, []) == nil
    end
  end
end
