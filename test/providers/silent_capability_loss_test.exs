defmodule OptimalSystemAgent.Providers.SilentCapabilityLossTest do
  @moduledoc """
  One defect shape, found repeatedly across the provider layer:

  > a guard that is correct for one narrow case, applied one scope too wide,
  > silently disabling a capability, with no instrument reporting the loss.

  Each `describe` below pins one instance of it. What they have in common is
  more useful than any of them individually: none of these failures produced an
  error, a warning, or a wrong-looking request. They produced a *working* agent
  that was quietly less capable than the one the operator configured — for
  months, in some cases since the feature shipped.

  The reference for the correct shape is
  `Providers.OpenAICompat.maybe_add_provider_thinking/4`, which gates on
  TRANSPORT rather than capability and whose `deepseek_endpoint?(nil)` clause
  returns `true` specifically so an unknown cannot silently disable thinking.

  > #### Bedrock is unverified against a live call {: .warning}
  >
  > There are no Bedrock credentials on this machine. The Bedrock section below
  > tests the request body OSA assembles against AWS's documented Converse
  > shape. No request it builds has been sent to Bedrock.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Providers.Bedrock
  alias OptimalSystemAgent.Providers.GoogleModels
  alias OptimalSystemAgent.Providers.Ollama

  setup do
    prev = %{
      default_provider: Application.get_env(:optimal_system_agent, :default_provider),
      thinking_enabled: Application.get_env(:optimal_system_agent, :thinking_enabled),
      ollama_tools: Application.get_env(:optimal_system_agent, :ollama_tools),
      effort: Effort.current()
    }

    on_exit(fn ->
      restore(:default_provider, prev.default_provider)
      restore(:thinking_enabled, prev.thinking_enabled)
      restore(:ollama_tools, prev.ollama_tools)
      Effort.set(prev.effort)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # ── 1. A global read inside a per-request decision ────────────────────────

  describe "thinking is decided by the provider of THIS request" do
    # `thinking_config/1` read `is_anthropic_provider?()` — the configured
    # DEFAULT provider — alongside the already-correct `state.provider` check.
    # A user whose default is :ollama and who routes a turn to Anthropic (a
    # /model switch, a fallback-chain hop, a delegate with its own provider)
    # passed the request check and was still denied thinking, for the whole
    # session, with nothing reporting it.
    test "an Anthropic turn thinks even when the DEFAULT provider is not Anthropic" do
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:medium)

      state = %{provider: :anthropic, model: "claude-sonnet-4-6"}

      assert {config, source} = LLMClient.thinking_decision(state)

      assert is_map(config),
             "the request named :anthropic; what the DEFAULT provider happens to be is a " <>
               "question about configuration, not about this request"

      assert source in [:adaptive, :budget]
    end

    test "a request that names no provider still falls back to the configured default" do
      # `nil` genuinely means "the caller did not say", and for that question the
      # default provider IS the answer. This half of the old guard was correct
      # and must not be lost while removing the other half.
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:medium)

      assert {nil, :not_anthropic} =
               LLMClient.thinking_decision(%{provider: nil, model: nil})

      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

      assert {config, _} = LLMClient.thinking_decision(%{provider: nil, model: nil})
      assert is_map(config)
    end

    test "the decision reports WHY it is off, not just that it is" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :thinking_enabled, false)

      assert {nil, :disabled_by_config} =
               LLMClient.thinking_decision(%{provider: :anthropic, model: "claude-sonnet-4-6"})

      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:fast)

      assert {nil, :fast_mode} =
               LLMClient.thinking_decision(%{provider: :anthropic, model: "claude-sonnet-4-6"})
    end

    # A default that disables. Reasoning moves a model's score by ~10-11 points
    # (cline measured 68.5% vs 57.3% on Terminal-Bench 2.0 for glm-5.2 with and
    # without it), and the usual justification for defaulting a capability off
    # does not hold here: enabling thinking RAISES the Anthropic HTTP timeout
    # (120s -> 600s) rather than lowering it, and the Anthropic body carries no
    # `temperature`, so the "temperature must be 1 with extended thinking" 400
    # cannot fire.
    test "thinking defaults ON rather than requiring an env var to discover" do
      Application.delete_env(:optimal_system_agent, :thinking_enabled)
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Effort.set(:medium)

      assert {config, _source} =
               LLMClient.thinking_decision(%{provider: :anthropic, model: "claude-sonnet-4-6"})

      assert is_map(config),
             "an unset OSA_THINKING_ENABLED must not mean 'off' on the one provider whose " <>
               "current models are built around extended thinking"
    end
  end

  # ── 2. A constant standing in for a ladder ────────────────────────────────

  describe "the effort ladder reaches Gemini 2.5" do
    # `Google.put_thinking_budget/2` read `Keyword.get(opts, :thinking_budget,
    # 8192)` and stopped. Nothing in the agent loop passes `:thinking_budget`,
    # so the default WAS the value: five effort tiers, one request. Its sibling
    # `put_thinking_level/3` had consulted effort since the 3.x fix.
    @gemini25 "gemini-2.5-flash"

    test "each effort tier produces a distinct budget" do
      budgets =
        for effort <- [:fast, :low, :medium, :high, :max],
            do: GoogleModels.thinking_budget(@gemini25, effort)

      assert Enum.all?(budgets, &is_integer/1)

      assert length(Enum.uniq(budgets)) > 1,
             "a ladder whose rungs are all the same value is not a ladder; got " <>
               inspect(budgets)

      assert budgets == Enum.sort(budgets),
             "more effort must never mean less thinking; got #{inspect(budgets)}"
    end

    test "every rung is legal on every 2.5 variant" do
      # 2.5 Pro takes 128-32,768 and cannot be disabled; Flash takes 0-24,576;
      # Flash-Lite takes 0 or 512-24,576. The common window is 128..24,576, and
      # nothing may map to 0 — on Flash that switches thinking off outright,
      # which is the exact failure this whole file is about.
      for effort <- [:off, :fast, :low, :medium, :high, :max, :ultra, "garbage"] do
        budget = GoogleModels.thinking_budget(@gemini25, effort)

        assert is_integer(budget) and budget >= 128 and budget <= 24_576,
               "#{inspect(effort)} produced #{inspect(budget)}, outside the range every " <>
                 "Gemini 2.5 variant accepts"
      end
    end

    test "a model that does not take a raw budget gets none" do
      # thinkingLevel and thinkingBudget are mutually exclusive; the wrong one is
      # a hard request error, so an unknown dialect must stay silent here.
      assert GoogleModels.thinking_budget("gemini-3.6-flash", :high) == nil
    end
  end

  # ── 3. A capability with no path at all ───────────────────────────────────

  describe "Bedrock carries reasoning (request shape only — never sent live)" do
    @claude_on_bedrock "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

    defp bedrock_body(opts) do
      Bedrock.build_request_body(
        [%{role: "user", content: "hi"}],
        Keyword.get(opts, :model, @claude_on_bedrock),
        opts
      )
    end

    test "a Claude model on Bedrock is asked to reason" do
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:high)

      body = bedrock_body(max_tokens: 64_000)

      assert %{"reasoning_config" => %{"type" => "enabled", "budget_tokens" => budget}} =
               body["additionalModelRequestFields"]

      assert is_integer(budget) and budget >= 1_024
    end

    test "the effort ladder is visible in the request" do
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)

      budgets =
        for level <- [:medium, :high, :xhigh, :ultra] do
          Effort.set(level)
          get_in(bedrock_body(max_tokens: 128_000), ~w(additionalModelRequestFields
            reasoning_config budget_tokens))
        end

      assert Enum.all?(budgets, &is_integer/1)

      assert length(Enum.uniq(budgets)) > 1,
             "before this existed, all five tiers produced byte-identical Bedrock " <>
               "requests; got #{inspect(budgets)}"
    end

    test "temperature and topP are withdrawn when reasoning is on" do
      # Documented Bedrock constraint: sending either alongside reasoning is a
      # ValidationException.
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:medium)

      body = bedrock_body(max_tokens: 64_000, temperature: 0.7, top_p: 0.9)

      assert body["additionalModelRequestFields"]
      config = Map.get(body, "inferenceConfig", %{})
      refute Map.has_key?(config, "temperature")
      refute Map.has_key?(config, "topP")
      assert config["maxTokens"] == 64_000
    end

    test "budget_tokens stays strictly under maxTokens" do
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:max)

      body = bedrock_body(max_tokens: 4_096)

      budget =
        get_in(body, ~w(additionalModelRequestFields reasoning_config budget_tokens))

      assert budget < 4_096,
             "Bedrock refuses a budget at or above maxTokens; the budget must yield"
    end

    test "a maxTokens too small for any legal budget drops reasoning rather than 400ing" do
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:max)

      body = bedrock_body(max_tokens: 512)

      refute Map.has_key?(body, "additionalModelRequestFields"),
             "below Anthropic's 1,024-token minimum there is no legal budget; a degraded " <>
               "request beats a rejected one"
    end

    test "a non-Anthropic Bedrock model gets no Anthropic-shaped field" do
      # Nova and Titan use different fields and DeepSeek-R1 needs none, so an
      # unrecognised model must NOT default this on: the field is proprietary
      # and the failure is a hard 400, not a degraded answer.
      body = bedrock_body(model: "amazon.nova-pro-v1:0", max_tokens: 8_192)

      refute Map.has_key?(body, "additionalModelRequestFields")
      assert {nil, :model_unsupported} = Bedrock.reasoning_decision("amazon.nova-pro-v1:0", [])
    end

    test "fast mode and an explicit off are both honoured and both named" do
      Application.put_env(:optimal_system_agent, :thinking_enabled, true)
      Effort.set(:fast)
      assert {nil, :fast_mode} = Bedrock.reasoning_decision(@claude_on_bedrock, [])

      Effort.set(:medium)
      Application.put_env(:optimal_system_agent, :thinking_enabled, false)
      assert {nil, :disabled_by_config} = Bedrock.reasoning_decision(@claude_on_bedrock, [])
    end
  end

  # ── 4. A capability predicate stripping the whole toolbox ─────────────────

  describe "Ollama withholds tools only on evidence" do
    # `maybe_add_tools/3` stripped every tool schema whenever
    # `model_supports_tools?/1` said no, and that predicate ends in a fixed list
    # of model-name prefixes — so any model released after the list was written
    # answered "no". The result is not a degraded agent, it is a chatbot: it
    # cannot read a file or run a command. The only report was a Logger.debug.
    test "an unrecognised model family gets tools rather than losing them" do
      Application.delete_env(:optimal_system_agent, :ollama_tools)

      assert {true, :unknown_model_default} =
               Ollama.tools_decision("brand-new-model-nobody-has-heard-of:200b", [])
    end

    test "the size guard is kept — it protects against a real failure" do
      Application.delete_env(:optimal_system_agent, :ollama_tools)

      assert {false, :tiny_model_guard} = Ollama.tools_decision("llama3.2:3b", [])
      assert {false, :tiny_model_guard} = Ollama.tools_decision("qwen3:1.5b", [])
    end

    test "a known tool-capable family is recognised by name" do
      Application.delete_env(:optimal_system_agent, :ollama_tools)
      assert {true, source} = Ollama.tools_decision("qwen3:32b", [])
      assert source in [:name_prefix, :catalog, :cloud_capability]
    end

    test "OLLAMA_TOOLS overrides in both directions" do
      Application.put_env(:optimal_system_agent, :ollama_tools, false)
      assert {false, :config} = Ollama.tools_decision("qwen3:32b", [])

      Application.put_env(:optimal_system_agent, :ollama_tools, true)
      assert {true, :config} = Ollama.tools_decision("llama3.2:3b", [])

      # A per-request opt beats the config, as it does for OLLAMA_THINK.
      assert {false, :opt} = Ollama.tools_decision("qwen3:32b", tools_enabled: false)
    end

    test "a withheld toolbox is announced at a level someone will see" do
      Application.put_env(:optimal_system_agent, :ollama_tools, false)
      Process.delete(:osa_ollama_tools_stripped)

      tools = [%{name: "file_read", description: "read a file", parameters: %{}}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Ollama.apply_tools(%{model: "qwen3:32b"}, "qwen3:32b", tools: tools) ==
                   %{model: "qwen3:32b"}
        end)

      assert log =~ "withheld",
             "the loss of every tool must not be a debug-level detail"

      assert log =~ "[warning]",
             "a Logger.debug is how this went unnoticed in the first place"
    end

    test "tools survive when the decision says yes" do
      Application.put_env(:optimal_system_agent, :ollama_tools, true)
      tools = [%{name: "file_read", description: "read a file", parameters: %{}}]

      body = Ollama.apply_tools(%{}, "anything-at-all", tools: tools)
      assert [%{} | _] = body[:tools]
    end
  end
end
