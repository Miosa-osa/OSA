defmodule OptimalSystemAgent.Tools.Builtins.DelegateTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Delegate
  alias OptimalSystemAgent.Tools.Builtins.Delegate.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.Delegate.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ────────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'delegate'" do
      assert Constants.tool_name() == "delegate"
    end

    test "tiers/0 returns the three tiers" do
      assert Constants.tiers() == ~w(elite specialist utility)
    end

    test "min_subagent_tier/0 returns :specialist" do
      assert Constants.min_subagent_tier() == :specialist
    end

    test "roles/0 is a non-empty list of strings" do
      roles = Constants.roles()
      assert is_list(roles)
      assert length(roles) > 0
      assert Enum.all?(roles, &is_binary/1)
    end
  end

  # ── Shim surface (flat-layout backwards compat) ───────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert Delegate.name() == "delegate"
    end

    test "description/0 returns a non-empty string" do
      desc = Delegate.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns a map with required task field" do
      params = Delegate.parameters()
      assert is_map(params)
      assert params["required"] == ["task"]
      assert Map.has_key?(params["properties"], "task")
    end

    test "safety/0 returns :subagent" do
      assert Delegate.safety() == :subagent
    end

    test "available?/0 returns true" do
      assert Delegate.available?() == true
    end
  end

  # ── Tool module (structured layout) ──────────────────────────────────────

  describe "Tool callbacks" do
    test "name/0 returns 'delegate'" do
      assert Tool.name() == "delegate"
    end

    test "should_defer?/0 is false" do
      refute Tool.should_defer?()
    end

    test "always_load?/0 is true" do
      assert Tool.always_load?()
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only?/2 is false" do
      refute Tool.read_only?(%{}, UseContext.empty())
    end

    test "destructive?/2 is false" do
      refute Tool.destructive?(%{}, UseContext.empty())
    end

    test "open_world?/2 is true" do
      assert Tool.open_world?(%{}, UseContext.empty())
    end

    test "safety/0 is :subagent" do
      assert Tool.safety() == :subagent
    end

    test "aliases/0 includes 'agent'" do
      assert "agent" in Tool.aliases()
    end

    test "max_result_size_chars/0 is bounded (not :infinity)" do
      size = Tool.max_result_size_chars()
      assert is_integer(size) and size > 0
    end

    test "to_classifier_input/1 extracts task" do
      assert Tool.to_classifier_input(%{"task" => "do something"}) == %{task: "do something"}
    end

    test "to_classifier_input/1 returns empty string for missing task" do
      assert Tool.to_classifier_input(%{}) == ""
    end

    # P6 peer-resume (sibling handoff) — schema must expose the seeding param.
    test "parameters/0 exposes resume_from_agent_id as an optional string" do
      props = Tool.parameters()["properties"]
      assert %{"type" => "string"} = props["resume_from_agent_id"]
      refute "resume_from_agent_id" in Tool.parameters()["required"]
    end
  end

  # ── Prompt ───────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    # These used to assert on markdown HEADINGS ("## When to Use"). The prompt
    # was condensed to cut the static prefix, so the headings are gone and the
    # guidance is prose. Assert the GUIDANCE instead — that is what the pins
    # were protecting, and it survives a rewording of the section titles.
    test "says what to delegate for" do
      rendered = Prompt.render([])
      assert rendered =~ "parallelizable"
      assert rendered =~ "explore"
    end

    test "says what NOT to delegate, and names the alternative" do
      rendered = Prompt.render([])
      assert rendered =~ "single-file"
      # cross-tool reference — the model must be pointed at ask_user, not delegate
      assert rendered =~ "ask_user"
    end

    # These two rules were relocated from the description into the parameter
    # schema, where the model is composing the value they constrain. The
    # invariant is that they reach the model at all — the whole serialized tool
    # is what reaches it, so that is what the test asserts against. Pinning
    # these to the description string is what would block the next relocation.
    test "tells the model how to brief a subagent that cannot see the conversation" do
      payload = serialized()
      assert payload =~ "NOT seen this conversation"
      assert payload =~ "constraints"
    end

    test "carries the background/foreground contract" do
      payload = serialized()
      assert Prompt.render([]) =~ "Background is the DEFAULT"
      assert Prompt.render([]) =~ "do NOT poll"
      assert payload =~ "BLOCKS you and the user"
    end

    defp serialized do
      Jason.encode!(%{
        "description" => OptimalSystemAgent.Tools.Builtins.Delegate.Tool.description(),
        "input_schema" => OptimalSystemAgent.Tools.Builtins.Delegate.Tool.parameters()
      })
    end

    test "contains 'Roles' section" do
      assert Prompt.render([]) =~ "Roles"
    end

    test "renders without error" do
      result = Prompt.render([])
      assert is_binary(result)
      assert byte_size(result) > 100
    end
  end

  # ── Handler: validate/2 ───────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "passes with binary task" do
      assert {:ok, _} = Handler.validate(%{"task" => "do something"}, UseContext.empty())
    end

    test "fails with non-string task" do
      assert {:error, msg, -32_602} = Handler.validate(%{"task" => 123}, UseContext.empty())
      assert msg =~ "string"
    end

    test "fails with missing task" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "task"
    end
  end

  # ── Handler: check_permissions/2 ─────────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "allows non-blank task" do
      assert {:allow, _} =
               Handler.check_permissions(%{"task" => "do something"}, UseContext.empty())
    end

    test "denies blank task" do
      assert {:deny, msg} =
               Handler.check_permissions(%{"task" => "   "}, UseContext.empty())

      assert String.starts_with?(msg, "Access denied: ")
    end

    test "denies empty task" do
      assert {:deny, msg} =
               Handler.check_permissions(%{"task" => ""}, UseContext.empty())

      assert String.starts_with?(msg, "Access denied: ")
    end
  end

  # ── Handler: hard delegation-depth ceiling (finding 16) ──────────────────
  #
  # ToolFilter strips the delegate tool once depth >= max, but that is heuristic
  # and lossy — a surviving call must still be denied here to close the fork-bomb
  # ceiling on every spawn path.
  describe "Handler.check_permissions/2 depth ceiling" do
    alias OptimalSystemAgent.Agent.Loop.ToolFilter

    defp depth_ctx(depth) do
      %{UseContext.empty() | delegation_depth: depth}
    end

    test "denies delegation at the depth limit" do
      max = ToolFilter.max_delegation_depth()

      assert {:deny, msg} =
               Handler.check_permissions(%{"task" => "spawn more"}, depth_ctx(max))

      assert msg =~ "depth limit"
    end

    test "denies delegation above the depth limit" do
      max = ToolFilter.max_delegation_depth()

      assert {:deny, msg} =
               Handler.check_permissions(%{"task" => "spawn more"}, depth_ctx(max + 5))

      assert msg =~ "depth limit"
    end

    test "allows delegation below the depth limit (not denied for depth)" do
      max = ToolFilter.max_delegation_depth()

      assert {:allow, _} =
               Handler.check_permissions(%{"task" => "spawn more"}, depth_ctx(max - 1))
    end
  end

  # ── Handler: tri-mode delegation policy (primitive #34) ──────────────────

  defp policy_ctx(policy, messages) do
    %{UseContext.empty() | delegation_policy: policy, messages: messages}
  end

  describe "Handler.check_permissions/2 delegation policy" do
    test "proactive policy allows delegation" do
      assert {:allow, _} =
               Handler.check_permissions(%{"task" => "do X"}, policy_ctx(:proactive, []))
    end

    test "nil policy (config default :proactive) allows delegation" do
      assert {:allow, _} =
               Handler.check_permissions(%{"task" => "do X"}, policy_ctx(nil, []))
    end

    test "disabled policy denies delegation" do
      assert {:deny, msg} =
               Handler.check_permissions(%{"task" => "do X"}, policy_ctx(:disabled, []))

      assert msg =~ "disabled"
    end

    test "explicit_only denies when the user did not ask to delegate" do
      messages = [%{role: "user", content: "please fix the failing test"}]

      assert {:deny, msg} =
               Handler.check_permissions(
                 %{"task" => "do X"},
                 policy_ctx(:explicit_only, messages)
               )

      assert msg =~ "explicit-only"
    end

    test "explicit_only allows when the user asked to delegate" do
      messages = [%{role: "user", content: "delegate this to a subagent, please"}]

      assert {:allow, _} =
               Handler.check_permissions(
                 %{"task" => "do X"},
                 policy_ctx(:explicit_only, messages)
               )
    end

    test "explicit_only accepts string policy form 'explicit-only'" do
      assert {:deny, _} =
               Handler.check_permissions(%{"task" => "do X"}, policy_ctx("explicit-only", []))
    end
  end

  # ── UI.render/3 ──────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use stage returns kind 'delegate'" do
      result = UI.render(:tool_use, %{"task" => "analyze codebase"}, [])
      assert result.kind == "delegate"
      assert result.task == "analyze codebase"
    end

    test ":tool_use stage captures tier and role" do
      result =
        UI.render(:tool_use, %{"task" => "x", "tier" => "elite", "role" => "architect"}, [])

      assert result.tier == "elite"
      assert result.role == "architect"
    end

    test ":tool_use stage captures background flag" do
      result = UI.render(:tool_use, %{"task" => "x", "background" => true}, [])
      assert result.background == true
    end

    test ":tool_result stage returns kind 'delegate_result'" do
      result = UI.render(:tool_result, "Analysis complete.\nLine 2.", [])
      assert result.kind == "delegate_result"
      assert result.summary == "Analysis complete."
    end

    test ":tool_result stage includes byte count" do
      content = "hello"
      result = UI.render(:tool_result, content, [])
      assert result.bytes == byte_size(content)
    end

    test ":rejected stage returns kind 'delegate_rejected'" do
      result = UI.render(:rejected, %{}, [])
      assert result.kind == "delegate_rejected"
    end

    test ":error stage returns kind 'delegate_error' with message" do
      result = UI.render(:error, "something went wrong", [])
      assert result.kind == "delegate_error"
      assert result.message == "something went wrong"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, %{}, []) == nil
    end
  end
end
