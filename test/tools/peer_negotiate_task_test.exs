defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTaskTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask
  alias OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ──────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'peer_negotiate_task'" do
      assert Constants.tool_name() == "peer_negotiate_task"
    end

    test "actions/0 returns the four valid actions" do
      assert Constants.actions() == ["counter", "accept", "reject", "status"]
    end
  end

  # ── Shim surface ───────────────────────────────────────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert PeerNegotiateTask.name() == "peer_negotiate_task"
    end

    test "description/0 returns a non-empty string" do
      desc = PeerNegotiateTask.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 requires action and negotiation_id" do
      params = PeerNegotiateTask.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
      assert "negotiation_id" in params["required"]
    end

    test "should_defer?/0 is true" do
      assert PeerNegotiateTask.should_defer?() == true
    end

    test "safety/0 is :write_safe" do
      assert PeerNegotiateTask.safety() == :write_safe
    end

    test "concurrency_safe?/2 is false (negotiations serialize)" do
      refute PeerNegotiateTask.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only?/2 is false" do
      refute PeerNegotiateTask.read_only?(%{}, UseContext.empty())
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────────

  describe "Tool" do
    test "is structured? (exports execute/2)" do
      assert function_exported?(Tool, :execute, 2)
    end

    test "name/0 returns 'peer_negotiate_task'" do
      assert Tool.name() == "peer_negotiate_task"
    end

    test "should_defer?/0 is true" do
      assert Tool.should_defer?() == true
    end

    test "concurrency_safe?/2 is false" do
      refute Tool.concurrency_safe?(%{}, UseContext.empty())
    end
  end

  # ── Handler: validate ─────────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid 'counter' with negotiation_id" do
      assert {:ok, _} =
               Handler.validate(
                 %{"action" => "counter", "negotiation_id" => "neg-123"},
                 UseContext.empty()
               )
    end

    test "accepts valid 'accept' with negotiation_id" do
      assert {:ok, _} =
               Handler.validate(
                 %{"action" => "accept", "negotiation_id" => "neg-123"},
                 UseContext.empty()
               )
    end

    test "accepts valid 'status' with negotiation_id" do
      assert {:ok, _} =
               Handler.validate(
                 %{"action" => "status", "negotiation_id" => "neg-123"},
                 UseContext.empty()
               )
    end

    test "rejects valid action without negotiation_id" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "accept"}, UseContext.empty())

      assert msg =~ "negotiation_id"
    end

    test "rejects unknown action" do
      assert {:error, msg, -32_602} =
               Handler.validate(
                 %{"action" => "reassign", "negotiation_id" => "n"},
                 UseContext.empty()
               )

      assert msg =~ "Invalid action"
    end

    test "rejects missing input" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "Missing required parameters"
    end
  end

  # ── Handler: check_permissions ────────────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "allows normal context" do
      input = %{"action" => "status", "negotiation_id" => "neg-1"}
      assert {:allow, _} = Handler.check_permissions(input, UseContext.empty())
    end

    test "denies read-only context" do
      ctx = %{UseContext.empty() | read_only_request?: true}
      input = %{"action" => "accept", "negotiation_id" => "neg-1"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx)
      assert msg =~ "Access denied"
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "contains action descriptions" do
      prompt = Prompt.render([])
      assert prompt =~ "counter"
      assert prompt =~ "accept"
      assert prompt =~ "reject"
    end

    test "references sibling peer tools" do
      prompt = Prompt.render([])
      assert prompt =~ "peer_review" or prompt =~ "peer_claim_region"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind 'peer_negotiate_task'" do
      result =
        UI.render(:tool_use, %{"action" => "counter", "negotiation_id" => "n-1"}, [])

      assert result[:kind] == "peer_negotiate_task"
      assert result[:action] == "counter"
    end

    test ":tool_result returns kind 'peer_negotiate_task_result'" do
      result = UI.render(:tool_result, "Counter submitted.", [])
      assert result[:kind] == "peer_negotiate_task_result"
    end

    test ":error returns kind 'peer_negotiate_task_error'" do
      result = UI.render(:error, "not found", [])
      assert result[:kind] == "peer_negotiate_task_error"
      assert result[:message] == "not found"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, nil, []) == nil
    end
  end
end
