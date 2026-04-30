defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgentsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents
  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Tool
  alias OptimalSystemAgent.Tools.UseContext

  # ── Constants ──────────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name/0 returns 'mixture_of_agents'" do
      assert Constants.tool_name() == "mixture_of_agents"
    end

    test "candidate_providers/0 includes common providers" do
      providers = Constants.candidate_providers()
      assert is_list(providers)
      assert :anthropic in providers
      assert :openai in providers
      assert :groq in providers
    end

    test "provider_timeout_ms/0 is a positive integer" do
      timeout = Constants.provider_timeout_ms()
      assert is_integer(timeout)
      assert timeout > 0
    end

    test "synthesis_max_tokens/0 is a positive integer" do
      tokens = Constants.synthesis_max_tokens()
      assert is_integer(tokens)
      assert tokens > 0
    end
  end

  # ── Shim surface ───────────────────────────────────────────────────────────

  describe "shim module" do
    test "name/0 delegates to Tool" do
      assert MixtureOfAgents.name() == "mixture_of_agents"
    end

    test "description/0 returns a non-empty string" do
      desc = MixtureOfAgents.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 requires query" do
      params = MixtureOfAgents.parameters()
      assert params["type"] == "object"
      assert "query" in params["required"]
    end

    test "should_defer?/0 is true" do
      assert MixtureOfAgents.should_defer?() == true
    end

    test "safety/0 is :subagent" do
      assert MixtureOfAgents.safety() == :subagent
    end

    test "concurrency_safe?/2 is true (MoA parallelises internally)" do
      assert MixtureOfAgents.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only?/2 is false" do
      refute MixtureOfAgents.read_only?(%{}, UseContext.empty())
    end
  end

  # ── Tool module callbacks ─────────────────────────────────────────────────

  describe "Tool" do
    test "is structured? (exports execute/2)" do
      assert function_exported?(Tool, :execute, 2)
    end

    test "name/0 returns 'mixture_of_agents'" do
      assert Tool.name() == "mixture_of_agents"
    end

    test "should_defer?/0 is true" do
      assert Tool.should_defer?() == true
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "safety/0 is :subagent" do
      assert Tool.safety() == :subagent
    end
  end

  # ── Handler: validate ─────────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid query" do
      assert {:ok, _} =
               Handler.validate(%{"query" => "What is 2+2?"}, UseContext.empty())
    end

    test "rejects empty query string" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"query" => ""}, UseContext.empty())

      assert msg =~ "non-empty"
    end

    test "rejects non-string query" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"query" => 42}, UseContext.empty())

      assert msg =~ "non-empty string" or msg =~ "query"
    end

    test "rejects missing query" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, UseContext.empty())
      assert msg =~ "Missing required parameter: query"
    end
  end

  # ── Handler: check_permissions ────────────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "allows normal context" do
      assert {:allow, _} =
               Handler.check_permissions(%{"query" => "test"}, UseContext.empty())
    end

    test "allows read-only context (MoA just fans out queries)" do
      ctx = %{UseContext.empty() | read_only_request?: true}
      assert {:allow, _} = Handler.check_permissions(%{"query" => "test"}, ctx)
    end
  end

  # ── Handler: execute — not-enough-providers fast-path ─────────────────────

  describe "Handler.execute/2 — provider availability" do
    test "returns informative message when only 1 provider is requested" do
      # Use a known valid atom but only one provider — triggers the
      # "requires at least 2 providers" fast-path.
      ctx = UseContext.empty()

      result =
        Handler.execute(
          %{"query" => "test", "providers" => ["anthropic"]},
          ctx
        )

      assert {:ok, msg} = result
      assert msg =~ "at least 2 providers"
    end
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  describe "Prompt.render/1" do
    test "mentions multiple providers" do
      prompt = Prompt.render([])
      assert prompt =~ "providers" or prompt =~ "provider"
    end

    test "mentions synthesis" do
      prompt = Prompt.render([])
      assert prompt =~ "synth" or prompt =~ "combine" or prompt =~ "models"
    end

    test "references the delegate tool" do
      prompt = Prompt.render([])
      assert prompt =~ "delegate"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test ":tool_use returns kind 'mixture_of_agents'" do
      result = UI.render(:tool_use, %{"query" => "What is 2+2?"}, [])
      assert result[:kind] == "mixture_of_agents"
      assert result[:query_preview] =~ "What is"
    end

    test ":tool_result returns kind 'mixture_of_agents_result'" do
      result = UI.render(:tool_result, "Synthesis: 4.", [])
      assert result[:kind] == "mixture_of_agents_result"
    end

    test ":progress returns kind 'mixture_of_agents_progress'" do
      result = UI.render(:progress, %{provider: :anthropic, status: "running"}, [])
      assert result[:kind] == "mixture_of_agents_progress"
      assert result[:provider] == "anthropic"
    end

    test ":error returns kind 'mixture_of_agents_error'" do
      result = UI.render(:error, "timeout", [])
      assert result[:kind] == "mixture_of_agents_error"
      assert result[:message] == "timeout"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown_stage, nil, []) == nil
    end
  end
end
