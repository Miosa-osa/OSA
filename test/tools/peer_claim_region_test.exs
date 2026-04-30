defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegionTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.PeerClaimRegion
  alias OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ──────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'peer_claim_region'" do
      assert Constants.tool_name() == "peer_claim_region"
    end

    test "actions/0 returns the four valid actions" do
      assert Constants.actions() == ["claim", "release", "list", "touch"]
    end

    test "claim_ttl_seconds/0 returns a positive integer" do
      ttl = Constants.claim_ttl_seconds()
      assert is_integer(ttl)
      assert ttl > 0
    end
  end

  # ── Shim surface ───────────────────────────────────────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert PeerClaimRegion.name() == "peer_claim_region"
    end

    test "description/0 returns a non-empty string" do
      desc = PeerClaimRegion.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 requires action and file_path" do
      params = PeerClaimRegion.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
      assert "file_path" in params["required"]
    end

    test "should_defer?/0 is true" do
      assert PeerClaimRegion.should_defer?() == true
    end

    test "safety/0 is :write_safe" do
      assert PeerClaimRegion.safety() == :write_safe
    end

    test "concurrency_safe?/2 is false (claims serialize)" do
      refute PeerClaimRegion.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only?/2 is false" do
      refute PeerClaimRegion.read_only?(%{}, UseContext.empty())
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────────

  describe "Tool" do
    test "is structured? (exports execute/2)" do
      assert function_exported?(Tool, :execute, 2)
    end

    test "name/0 returns 'peer_claim_region'" do
      assert Tool.name() == "peer_claim_region"
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
    test "accepts valid 'claim' with file_path" do
      assert {:ok, _} =
               Handler.validate(
                 %{"action" => "claim", "file_path" => "/tmp/foo.ex"},
                 UseContext.empty()
               )
    end

    test "accepts valid 'list' with file_path" do
      assert {:ok, _} =
               Handler.validate(
                 %{"action" => "list", "file_path" => "/tmp/foo.ex"},
                 UseContext.empty()
               )
    end

    test "rejects valid action without file_path" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "claim"}, UseContext.empty())

      assert msg =~ "file_path"
    end

    test "rejects unknown action" do
      assert {:error, msg, -32_602} =
               Handler.validate(
                 %{"action" => "lock", "file_path" => "/tmp/f"},
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
      assert {:allow, _} =
               Handler.check_permissions(
                 %{"action" => "claim", "file_path" => "/tmp/x"},
                 UseContext.empty()
               )
    end

    test "denies read-only context" do
      ctx = %{UseContext.empty() | read_only_request?: true}

      assert {:deny, msg} =
               Handler.check_permissions(%{"action" => "claim", "file_path" => "/tmp/x"}, ctx)

      assert msg =~ "Access denied"
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "contains action descriptions" do
      prompt = Prompt.render([])
      assert prompt =~ "claim"
      assert prompt =~ "release"
    end

    test "references sibling peer tools" do
      prompt = Prompt.render([])
      assert prompt =~ "peer_review" or prompt =~ "peer_negotiate_task"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind 'peer_claim_region'" do
      result =
        UI.render(:tool_use, %{"action" => "claim", "file_path" => "/tmp/f.ex"}, [])

      assert result[:kind] == "peer_claim_region"
      assert result[:action] == "claim"
      assert result[:file_path] == "/tmp/f.ex"
    end

    test ":tool_result returns kind 'peer_claim_region_result'" do
      result = UI.render(:tool_result, "Region claimed.", [])
      assert result[:kind] == "peer_claim_region_result"
    end

    test ":error returns kind 'peer_claim_region_error'" do
      result = UI.render(:error, "conflict", [])
      assert result[:kind] == "peer_claim_region_error"
      assert result[:message] == "conflict"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, nil, []) == nil
    end
  end
end
