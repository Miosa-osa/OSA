defmodule OptimalSystemAgent.Tools.Builtins.PeerReviewTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.PeerReview
  alias OptimalSystemAgent.Tools.Builtins.PeerReview.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.PeerReview.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ──────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'peer_review'" do
      assert Constants.tool_name() == "peer_review"
    end

    test "actions/0 returns the three valid actions" do
      assert Constants.actions() == ["request", "check", "submit"]
    end

    test "verdicts/0 returns the three valid verdicts" do
      assert Constants.verdicts() == ["approve", "request_changes", "reject"]
    end
  end

  # ── Shim surface ───────────────────────────────────────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert PeerReview.name() == "peer_review"
    end

    test "description/0 returns a non-empty string" do
      desc = PeerReview.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns valid JSON schema with action required" do
      params = PeerReview.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
      assert Map.has_key?(params["properties"], "action")
    end

    test "should_defer?/0 is true" do
      assert PeerReview.should_defer?() == true
    end

    test "safety/0 is :write_safe" do
      assert PeerReview.safety() == :write_safe
    end

    test "read_only?/2 is false" do
      refute PeerReview.read_only?(%{}, UseContext.empty())
    end

    test "concurrency_safe?/2 is true" do
      assert PeerReview.concurrency_safe?(%{}, UseContext.empty())
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────────

  describe "Tool" do
    test "is structured? (exports execute/2)" do
      assert function_exported?(Tool, :execute, 2)
    end

    test "name/0 returns 'peer_review'" do
      assert Tool.name() == "peer_review"
    end

    test "should_defer?/0 is true" do
      assert Tool.should_defer?() == true
    end

    test "safety/0 is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only?/2 is false" do
      refute Tool.read_only?(%{}, UseContext.empty())
    end
  end

  # ── Handler: validate ─────────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid 'request' action" do
      assert {:ok, %{"action" => "request"}} =
               Handler.validate(%{"action" => "request", "artifact" => "x"}, UseContext.empty())
    end

    test "accepts valid 'check' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "check"}, UseContext.empty())
    end

    test "accepts valid 'submit' action" do
      assert {:ok, _} = Handler.validate(%{"action" => "submit"}, UseContext.empty())
    end

    test "rejects unknown action" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "destroy"}, UseContext.empty())

      assert msg =~ "Invalid action"
    end

    test "rejects missing action" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "Missing required parameter: action"
    end
  end

  # ── Handler: check_permissions ────────────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "allows normal context" do
      assert {:allow, _} = Handler.check_permissions(%{"action" => "check"}, UseContext.empty())
    end

    test "denies read-only context" do
      ctx = %{UseContext.empty() | read_only_request?: true}
      assert {:deny, msg} = Handler.check_permissions(%{"action" => "request"}, ctx)
      assert msg =~ "Access denied"
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "contains workflow instructions" do
      prompt = Prompt.render([])
      assert prompt =~ "request"
      assert prompt =~ "check"
      assert prompt =~ "submit"
    end

    test "references sibling peer tools" do
      prompt = Prompt.render([])
      # Should mention peer_claim_region or peer_negotiate_task
      assert prompt =~ "peer_claim_region" or prompt =~ "peer_negotiate_task"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind 'peer_review'" do
      result = UI.render(:tool_use, %{"action" => "check"}, [])
      assert result[:kind] == "peer_review"
      assert result[:action] == "check"
    end

    test ":tool_result returns kind 'peer_review_result'" do
      result = UI.render(:tool_result, "Review approved.", [])
      assert result[:kind] == "peer_review_result"
    end

    test ":rejected returns kind 'peer_review_rejected'" do
      result = UI.render(:rejected, %{}, [])
      assert result[:kind] == "peer_review_rejected"
    end

    test ":error returns kind 'peer_review_error'" do
      result = UI.render(:error, "something went wrong", [])
      assert result[:kind] == "peer_review_error"
      assert result[:message] == "something went wrong"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, nil, []) == nil
    end
  end
end
