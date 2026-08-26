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

  require Logger

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Agent.FastPath
  alias OptimalSystemAgent.Providers.Bedrock
  alias OptimalSystemAgent.Providers.CacheAttribution
  alias OptimalSystemAgent.Providers.ClaudeCli
  alias OptimalSystemAgent.Providers.Cohere
  alias OptimalSystemAgent.Providers.CopilotCli
  alias OptimalSystemAgent.Providers.ImageBudget
  alias OptimalSystemAgent.Providers.GoogleModels
  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.PromptCache
  alias OptimalSystemAgent.Providers.Registry

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

  # `capture_log/2`'s `:level` option filters what is CAPTURED; it cannot raise
  # the Logger's own level, so an `:info` line emitted while the Logger sits at
  # `:warning` was never produced in the first place. Every assertion in this
  # file about a message being visible needs this.
  defp capture_info(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log([level: :info], fun)
    after
      Logger.configure(level: prev)
    end
  end

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

  # ── 5. The effort ladder reaches the gateways, not just the vendors ───────

  describe "reasoning effort survives an OpenAI-compatible gateway" do
    # `maybe_add_reasoning/3` was gated on `reasoning_model?/1`, which is three
    # hardcoded vendor name-tables plus `String.contains?(name, "kimi")`. Every
    # gateway this transport serves names its models `vendor/model`, so every
    # one of those ids answered "no" — including `anthropic/claude-opus-5`,
    # which is OpenRouter's DEFAULT model in `openai_compat_provider.ex`. The
    # whole `Agent.Effort` ladder was inert on the out-of-the-box OpenRouter
    # configuration, and the same predicate gates the 600s reasoning timeout,
    # so those turns also kept the 120s non-reasoning one.
    #
    # `scratchpad.ex` documents the symptom as a fact to design around. It was
    # a bug.
    @gateway_reasoners [
      "anthropic/claude-opus-5",
      "anthropic/claude-sonnet-5",
      "google/gemini-3.6-flash",
      "openai/gpt-5.6-sol",
      "deepseek/deepseek-v4-pro",
      "x-ai/grok-4.5"
    ]

    setup do
      Effort.set(:high)
      :ok
    end

    test "a vendor-prefixed reasoning model is asked to reason" do
      for model <- @gateway_reasoners do
        assert {value, source} = OpenAICompat.reasoning_decision(model, [])

        assert is_binary(value),
               "#{model} is a reasoning model reached through a gateway; the effort ladder " <>
                 "must not stop at the vendor prefix"

        assert source in [:catalog, :name_heuristic]
      end
    end

    test "the field actually lands in the request body" do
      body =
        OpenAICompat.build_stream_body(
          "anthropic/claude-opus-5",
          [%{role: "user", content: "hi"}],
          [],
          "https://openrouter.ai/api/v1"
        )

      assert body[:reasoning_effort] == "high"
    end

    test "the ladder is visible in the body — not one value at every tier" do
      efforts =
        for tier <- [:fast, :medium, :high, :xhigh, :ultra] do
          Effort.set(tier)

          OpenAICompat.build_stream_body(
            "anthropic/claude-opus-5",
            [%{role: "user", content: "hi"}],
            [],
            "https://openrouter.ai/api/v1"
          )[:reasoning_effort]
        end

      assert Enum.all?(efforts, &is_binary/1)

      assert length(Enum.uniq(efforts)) > 1,
             "before this, all five tiers produced byte-identical OpenRouter requests " <>
               "(no field at all); got #{inspect(efforts)}"
    end

    test "the 600s reasoning timeout follows the same answer" do
      assert OpenAICompat.reasoning_model?("anthropic/claude-opus-5"),
             "the reasoning HTTP timeout is gated on this predicate; a Claude reached " <>
               "through OpenRouter thinks for minutes and was given 120s"
    end

    test "a model that does not reason still gets nothing" do
      # The bar was not lowered, only the evidence widened. `reasoning_effort`
      # on a non-reasoning model is a hard 400 on a strict gateway, not a
      # degraded answer — the same asymmetry Bedrock respects for Nova.
      assert {nil, :model_unsupported} =
               OpenAICompat.reasoning_decision("llama-3.3-70b-versatile", [])

      body =
        OpenAICompat.build_stream_body(
          "llama-3.3-70b-versatile",
          [%{role: "user", content: "hi"}],
          [],
          "https://api.groq.com/openai/v1"
        )

      refute Map.has_key?(body, :reasoning_effort)
    end

    test "an explicit opt is honoured whatever the catalog thinks" do
      # This branch is unchanged from before the catalog consult existed, so
      # the widening cannot have cost an existing caller anything.
      assert {"low", :opt} =
               OpenAICompat.reasoning_decision("some-unknown-model", reasoning_effort: :low)
    end

    test "the catalog cannot VETO the name tables" do
      # A Catalog `false` is third-party data that lags. Making it
      # authoritative in the negative direction would be this file's own defect
      # shape pointed the other way, so the two authorities are a union.
      assert OpenAICompat.reasoning_model?("moonshotai/kimi-k2"),
             "the kimi name rule exists because the catalog was wrong; it must survive"
    end

    test "the decision is announced at a level someone will see" do
      Process.delete(:osa_compat_reasoning)

      # `config/test.exs` pins the Logger at :warning, which drops the record
      # BEFORE the capture handler sees it — so without this the assertion
      # below would pass or fail on the test config rather than on the code.
      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          OpenAICompat.build_stream_body(
            "anthropic/claude-opus-5",
            [%{role: "user", content: "hi"}],
            [],
            "https://openrouter.ai/api/v1"
          )
        end)

      assert log =~ "reasoning_effort"
      assert log =~ "[info]", "a fix that is also silent is not a fix"
    end
  end

  # ── 6. The instrument built to stop this was itself silent ────────────────

  describe "turn_start/turn_end record reasoning for the whole fleet" do
    # `Observability.current_reasoning/1` had arms for :ollama, :anthropic and
    # :bedrock and a `_ -> nil` catch-all — and `nil` on that field is
    # DOCUMENTED as "the provider/model has no such setting". It was recorded
    # for the ~19 compat-routed providers that DO have one. So a benchmark row
    # from an OpenRouter run read `effort=ultra, reasoning=` — indistinguishable
    # between the ladder being inert (which it was) and the ladder working.
    test "every compat-routed provider reports a reasoning decision" do
      Effort.set(:high)

      for provider <- Registry.compat_providers() do
        state = %{provider: provider, model: "anthropic/claude-opus-5"}

        assert reported = Observability.current_reasoning(state),
               "#{provider} is routed through OpenAICompat, which decides whether the " <>
                 "request carries reasoning_effort. Recording nil there means 'no such " <>
                 "setting', which is false."

        assert reported =~ ~r/^(on|off):/
      end
    end

    test "Google reports one too" do
      assert reported =
               Observability.current_reasoning(%{provider: :google, model: "gemini-2.5-flash"})

      assert reported =~ ~r/^on:/
    end

    test "the report names the rule, not just the value" do
      Effort.set(:fast)

      assert Observability.current_reasoning(%{
               provider: :openrouter,
               model: "llama-3.3-70b-versatile"
             }) =~ "model_unsupported"
    end
  end

  # ── 7. The same defect, unfixed at its twin site ──────────────────────────

  describe "a fix applied at one of two entrances" do
    # #6 in this file's history: `anthropic_prompt_cache?/2` guards on
    # `is_binary(model)` and `opts[:model]` is nil on every non-CLI entry point.
    # `Registry.resolved_model/2` was written to close that, applied at
    # `normalize_message_content/3`, and NOT at `PromptCache.restructure/3` —
    # the other consumer of the same predicate in the same pipeline.
    test "PromptCache resolves the served model, not the named one" do
      # The shape `Registry.normalize_message_content/3` hands on: a marked
      # stable prefix block followed by the unmarked volatile tail.
      messages = [
        %{
          role: "system",
          content: [
            %{
              type: "text",
              text: String.duplicate("stable prefix. ", 500),
              cache_control: %{"type" => "ephemeral"}
            },
            %{type: "text", text: "the time is 12:00:00.123456"}
          ]
        },
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "hi"},
        %{role: "user", content: "again"}
      ]

      with_model =
        PromptCache.restructure(messages, {:compat, :openrouter},
          model: "anthropic/claude-opus-5"
        )

      without_model = PromptCache.restructure(messages, {:compat, :openrouter}, [])

      assert without_model == with_model,
             "a caller that names no model — the compactor, the classifier, every " <>
               "provider-fallback hop — reaches the same Claude and must get the same " <>
               "cache structure"

      refute without_model == messages,
             "restructure/3 became a no-op whenever :model was absent from opts"
    end

    # #11: `function_exported?/3` answers false for a module not yet LOADED.
    # `stream_capable?/1` was given `Code.ensure_loaded?` and the fallback-hop
    # entrance — `do_try_stream_provider/4`, reached only from the provider
    # fallback loop, i.e. only for modules this process has NOT touched yet —
    # was left with the bare call.
    #
    # Asserted against the source rather than by purging a module: purging a
    # provider out from under a live suite is a worse test than the bug.
    test "the streaming entrance on the fallback hop is guarded too" do
      src = File.read!("lib/optimal_system_agent/providers/registry.ex")

      refute src =~ ~r/if function_exported\?\(module, :chat_stream/,
             "both stream entrances must go through `stream_capable?/1`, which pairs " <>
               "`Code.ensure_loaded?/1` with the export check"
    end

    test "a lost stream is announced, not just a working one" do
      Process.delete(:osa_stream_downgrade)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Registry.report_stream_downgrade(OptimalSystemAgent.Providers.Cohere, :primary)
        end)

      assert log =~ "does not implement chat_stream"

      assert log =~ "[warning]",
             "the success case logged at :info and the loss said nothing at all"
    end
  end

  # ── 8. Class-level: the shape, not the instances ──────────────────────────

  describe "the class" do
    @bare_fx_ratchet 43

    # Worth more than any of the instance tests above. Twelve of the fixed
    # defects were found one at a time; this one refuses the thirteenth
    # occurrence of the SHAPE.
    test "no NEW bare function_exported?/2,3 enters the tree" do
      {out, 0} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(grep -rn "function_exported?" lib --include='*.ex' | grep -vc "Code.ensure_loaded")
          ],
          cd: File.cwd!(),
          stderr_to_stdout: true
        )

      count = out |> String.trim() |> String.to_integer()

      assert count <= @bare_fx_ratchet, """
      #{count} bare `function_exported?` calls, up from the reviewed baseline of #{@bare_fx_ratchet}.

      `function_exported?/3` answers false for a module that has not been LOADED
      yet, so a bare call is a capability question that silently answers "no"
      under lazy code loading. It cost OSA a streaming provider
      (`Registry.stream_capable?/1`) and a permission check on write tools
      (`ToolExecutor.handler_hard_deny/1`, where it failed OPEN).

      Pair every new call with `Code.ensure_loaded?/1`. If the site genuinely
      fails closed and is harmless, lower this ratchet deliberately rather than
      raising it.
      """
    end

    # Every compat-routed provider bills on OpenAI's INCLUSIVE convention,
    # because they are all parsed by `OpenAICompat.parse_usage/1`. The
    # convention table was a hand-written list of atoms that had drifted:
    # :cerebras, :sambanova, :hyperbolic, :lmstudio, :llamacpp and :miosa were
    # all missing and fell through to Anthropic's disjoint convention — the 11x
    # over-bill the reconciler exists to prevent.
    test "no compat provider can silently acquire the wrong billing convention" do
      usage = %{
        input_tokens: 1000,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 900
      }

      for provider <- Registry.compat_providers() do
        norm = Accounting.reconcile_prompt_slices(usage, provider)

        assert norm.input_tokens == 100,
               "#{provider} is parsed by OpenAICompat.parse_usage/1, whose input_tokens is " <>
                 "INCLUSIVE of the cached slice. Left on the disjoint convention it bills " <>
                 "the cached prefix twice."
      end
    end

    # A provider that reports no usage is indistinguishable from one that used
    # no tokens: both normalise to zero, both price at $0.00, and
    # `max_budget_usd` silently stops being enforceable. Cohere and Replicate
    # were both in that state.
    test "a turn billed as zero because nothing was reported says so" do
      Process.delete(:osa_unaccounted_provider)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Accounting.report_unaccounted(%{provider: :replicate, model: "x"}, %{})
        end)

      assert log =~ "no token usage"
      assert log =~ "max_budget_usd"
      assert log =~ "[warning]"
    end

    test "Cohere reports usage under the four key names anything reads" do
      resp = %{"meta" => %{"tokens" => %{"input_tokens" => 120, "output_tokens" => 34}}}

      assert %{input_tokens: 120, output_tokens: 34} = Cohere.extract_usage(resp)

      assert Accounting.effective_input_tokens(Cohere.extract_usage(resp)) == 120,
             "a number filed under any other key is invisible to pricing"
    end

    # ── The counter that can only ever read zero ───────────────────────────
    #
    # Bedrock's `extract_usage/1` parsed `cacheReadInputTokens` and `:bedrock`
    # was placed in `Accounting`'s `@disjoint_prompt_slices` on the strength of
    # it — while NO `cachePoint` existed anywhere in `lib/`. A response-side
    # parser with no request-side marker does not report a cold cache; it
    # reports a plausible zero, indefinitely, and every consumer downstream
    # treats that zero as a measurement.
    #
    # This is the class test, not the Bedrock one: it refuses the NEXT provider
    # that parses a cache counter it cannot populate.
    test "a provider that parses a cache-read counter also emits a cache marker" do
      # Request-side markers, by provider wire format. A provider whose response
      # parser reads a cache slice must name one of these somewhere in its own
      # source, or the counter is structurally pinned at 0.
      markers = ~w(cache_control cachePoint cached_content cachedContent implicit)

      # The exemption is the point of the ratchet, not a hole in it: each entry
      # is a provider where OSA does NOT assemble the cached prefix, so there is
      # no request-side marker it could emit and the counter it parses is filled
      # by somebody else. Adding a name here should require writing the reason,
      # which is the discipline that was missing when Bedrock's counter was
      # added with no path behind it.
      #
      #   claude_cli / copilot_cli — OSA shells out to a vendor CLI. The CLI
      #     builds and caches its own request; OSA only reads the usage the CLI
      #     reports back. The counter is populated by a real cache.
      #   openai_responses — the Responses API caches automatically server-side
      #     with no request field at all; `cached_tokens` comes back without OSA
      #     asking for anything.
      exempt = ~w(claude_cli.ex copilot_cli.ex openai_responses.ex)

      lib = Path.join(File.cwd!(), "lib/optimal_system_agent/providers")

      offenders =
        lib
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.reject(&(&1 in exempt))
        |> Enum.map(&{&1, File.read!(Path.join(lib, &1))})
        |> Enum.filter(fn {_name, src} ->
          # Reads a cache slice back off the wire…
          # …but says nothing about how the prefix got marked.
          Regex.match?(~r/cache[_A-Za-z]*[Rr]ead[_A-Za-z]*[Tt]okens|cached_tokens/, src) and
            not Enum.any?(markers, &String.contains?(src, &1))
        end)
        |> Enum.map(&elem(&1, 0))

      assert offenders == [], """
      #{inspect(offenders)} parse a prompt-cache read counter but reference no
      request-side cache marker.

      That counter cannot be anything but 0. It is worse than an absent metric:
      session cost, `CacheAttribution` and the cache readouts all consume it as
      a measurement, so a capability that was never wired reads exactly like a
      capability that is working and simply never hits.

      Either mark the prefix on the request (Anthropic `cache_control`, Bedrock
      `cachePoint`, Gemini `cachedContent`) or stop parsing the counter and let
      the slice be honestly absent.
      """
    end

    # `ImageBudget.cap_for/1` was `:anthropic | :google | :gemini | _` — three
    # named providers and a 40 MB catch-all for the other ~25, including
    # providers documented lower than 40 MB. A cap above the provider's real
    # ceiling makes the eviction trigger unreachable: the guard cannot fire
    # before the provider rejects the request, so the whole hysteresis mechanism
    # is inert on every provider it was not written for.
    test "no provider silently inherits an unknown request-size cap" do
      providers =
        [:anthropic, :google, :bedrock, :ollama, :ollama_cloud, :claude_cli, :copilot_cli] ++
          Registry.compat_providers()

      for provider <- providers do
        assert {bytes, source} = ImageBudget.cap_for(provider)
        assert is_integer(bytes) and bytes > 0

        assert source != :unknown_provider,
               "#{provider} has no entry in ImageBudget.cap_for/1 and fell to the 40 MB " <>
                 "catch-all. If 40 MB is right for it, say so explicitly — an inherited " <>
                 "default is indistinguishable from an unconsidered one."
      end
    end

    # `image_payload/1` is a table of wire shapes, and a table is exactly the
    # thing that goes stale: Ollama gained a working image path and the table
    # did not learn it, so every counter — `images_remaining`, the byte
    # measurement, the eviction savings — read 0 for that provider while a
    # multi-MB payload sat in the body.
    test "every image wire shape OSA sends is visible to the budget" do
      data = String.duplicate("A", 4096)

      bodies = [
        {"anthropic",
         %{
           messages: [
             %{
               "role" => "user",
               "content" => [%{"type" => "image", "source" => %{"data" => data}}]
             }
           ]
         }},
        {"openai/compat",
         %{
           messages: [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/png;base64," <> data}
                 }
               ]
             }
           ]
         }},
        {"bedrock converse",
         %{
           messages: [
             %{
               "role" => "user",
               "content" => [%{"image" => %{"format" => "png", "source" => %{"bytes" => data}}}]
             }
           ]
         }},
        {"gemini",
         %{contents: [%{"role" => "user", "parts" => [%{"inlineData" => %{"data" => data}}]}]}},
        # Not a block inside `content` at all — a SIBLING of it. Every traversal
        # in ImageBudget reached images through the content list, so this shape
        # was invisible to all of them at once.
        {"ollama", %{messages: [%{"role" => "user", "content" => "look", "images" => [data]}]}}
      ]

      for {label, body} <- bodies do
        {_out, outcome} = ImageBudget.run(body, cap_bytes: 100_000_000)

        assert outcome.images_remaining == 1,
               "#{label}: the budget counted #{outcome.images_remaining} images in a body " <>
                 "carrying exactly one. A shape it cannot see is a shape it cannot evict."

        assert outcome.body_bytes_before >= byte_size(data),
               "#{label}: measured #{outcome.body_bytes_before} bytes for a body containing a " <>
                 "#{byte_size(data)}-byte payload"
      end
    end

    # 39 `vision:` flags across four OSA catalogues, reached through each
    # module's `capability(id, :vision)`, called by nothing. The gate consulted
    # only the bundled third-party catalog, under provider ids that catalog does
    # not have (`bedrock`, `ollama_cloud`, `claude_cli`), so it answered "yes,
    # this model takes images" for every one of them.
    test "a catalogue flag OSA maintains is a flag OSA reads" do
      # OllamaCloud is the catalogue that actually carries `vision: false`
      # entries, so it is the one where a dead flag has a visible cost.
      refute ImageBudget.vision_capable?(:ollama_cloud, "glm-4.7:cloud"),
             "OllamaCloud records `vision: false` for this tag. If the gate cannot reach " <>
               "that, the flag is decoration and an attached image is sent to a model that " <>
               "cannot see it."

      assert {false, :osa_catalogue} =
               ImageBudget.vision_decision(:ollama_cloud, "gpt-oss:120b-cloud")

      # A Bedrock inference-profile id names an Anthropic model that OSA's own
      # Anthropic catalogue knows. The old lookup keyed on the provider string
      # `"bedrock"`, which exists in no catalog anywhere.
      assert {true, :osa_catalogue} =
               ImageBudget.vision_decision(
                 :bedrock,
                 "us.anthropic.claude-sonnet-4-6-20250929-v1:0"
               )

      # And the documented fail-open survives: an unknown model keeps its images.
      assert {true, :unknown_default} =
               ImageBudget.vision_decision(:ollama, "some-local-tag-nobody-has-heard-of")
    end
  end

  # ── 9. Bedrock prompt caching (request shape only — never sent live) ──────

  describe "Bedrock marks a cacheable prefix" do
    @claude_bedrock "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

    defp cached_body(opts) do
      Bedrock.build_request_body(
        [
          %{role: "system", content: String.duplicate("stable system prefix. ", 500)},
          %{role: "user", content: "hi"}
        ],
        Keyword.get(opts, :model, @claude_bedrock),
        Keyword.merge([tools: bulky_tools()], opts)
      )
    end

    defp bulky_tools do
      for i <- 1..20,
          do: %{name: "tool_#{i}", description: String.duplicate("d", 300), parameters: %{}}
    end

    test "the static prefix carries a cachePoint on both scopes" do
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)

      body = cached_body([])

      assert %{"cachePoint" => %{"type" => "default"}} = List.last(body["system"])
      assert %{"cachePoint" => %{"type" => "default"}} = List.last(body["toolConfig"]["tools"])
    end

    test "the marker is the LAST element, not an interior one" do
      # cachePoint marks the END of a cacheable prefix. An interior marker
      # caches a proper subset and silently leaves the rest re-prefilling every
      # turn — a cache that is on, reports a positive read, and is still mostly
      # missing.
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)

      tools = cached_body([])["toolConfig"]["tools"]

      assert Enum.count(tools, &is_map_key(&1, "cachePoint")) == 1
      assert List.last(tools) |> is_map_key("cachePoint")
    end

    test "a prefix too small to cache is skipped and SAID to be skipped" do
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)

      Process.delete(:osa_bedrock_cache_points)

      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          body =
            Bedrock.build_request_body(
              [%{role: "system", content: "short"}, %{role: "user", content: "hi"}],
              @claude_bedrock,
              []
            )

          refute Enum.any?(body["system"] || [], &is_map_key(&1, "cachePoint")),
                 "a marker below the ~1,024-token minimum buys a cache-write premium and " <>
                   "no cache"
        end)

      assert log =~ "cache_read_input_tokens will stay 0",
             "the arms under which the counter can only read 0 must name themselves; an " <>
               "unexplained 0 is exactly what this whole file is about"
    end

    test "a non-Anthropic Bedrock model gets no cachePoint" do
      # Same asymmetry `reasoning_decision/2` applies for `reasoning_config`:
      # a proprietary field on an unrecognised family is a hard error, and a
      # marker that splits a prefix the model would have cached whole is a
      # silent loss.
      assert {[], :model_unsupported} = Bedrock.cache_point_decision("amazon.nova-pro-v1:0", [])
    end

    test "the kill switch reaches Bedrock, not only the Anthropic-native path" do
      # `prompt_caching_enabled` had all five of its call sites inside
      # `anthropic.ex`. Setting it false therefore disabled caching on the one
      # path that HAD it and left every other path untouched — the flag named a
      # global policy and enforced a per-module one.
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)

      assert {[], :disabled_by_config} = Bedrock.cache_point_decision(@claude_bedrock, [])

      body = cached_body([])
      refute Enum.any?(body["system"], &is_map_key(&1, "cachePoint"))
      refute Enum.any?(body["toolConfig"]["tools"], &is_map_key(&1, "cachePoint"))
    end
  end

  # ── 10. The instrument that could only report a break, never an absence ───

  describe "CacheAttribution reports a cache that never warmed" do
    setup do
      CacheAttribution.reset("silent-loss-scope")
      :ok
    end

    @fp CacheAttribution.fingerprint(%{
          model: "claude-opus-5",
          system: [%{"text" => "stable"}],
          tools: [],
          messages: [1, 2]
        })

    test "a permanently cold cache is named after a bounded number of turns" do
      # The old guard was `prev_read > 0 and read < prev_read`. Both halves are
      # correct for "what broke the cache" and together they make "was there
      # ever a cache" unaskable — a scope reading 0 forever never satisfies
      # `prev_read > 0`, so it renders no verdict and reads exactly like a
      # perfectly stable cache. That is the state OpenRouter was in for months.
      results =
        for _ <- 1..3 do
          CacheAttribution.observe("silent-loss-scope", @fp, %{cache_read_input_tokens: 0})
        end

      assert Enum.any?(results, &match?({:cold, _}, &1)),
             "three consecutive zero reads against a byte-identical prefix is not warm-up"

      {:cold, verdict} = Enum.find(results, &match?({:cold, _}, &1))
      assert verdict =~ "cache_read has been 0"
      assert verdict =~ "cachePoint" or verdict =~ "cache_control"
    end

    test "it is a warning, not a debug line" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3 do
            CacheAttribution.observe("silent-loss-scope", @fp, %{cache_read_input_tokens: 0})
          end
        end)

      assert log =~ "[PROMPT CACHE]"
      assert log =~ "[warning]"
    end

    test "a warm cache is never called cold" do
      for _ <- 1..5 do
        assert :ok =
                 CacheAttribution.observe("silent-loss-scope", @fp, %{
                   cache_read_input_tokens: 12_000
                 })
      end

      assert CacheAttribution.cold_run("silent-loss-scope") == 0
    end

    test "a legitimately changed prefix restarts the run rather than accusing it" do
      # A turn after the tool set changed HAS no cache to read from. Counting it
      # would make this instrument cry wolf, which is the failure mode that gets
      # an instrument ignored.
      other =
        CacheAttribution.fingerprint(%{
          model: "claude-opus-5",
          system: [%{"text" => "different"}],
          tools: [],
          messages: [1, 2]
        })

      CacheAttribution.observe("silent-loss-scope", @fp, %{cache_read_input_tokens: 0})
      CacheAttribution.observe("silent-loss-scope", other, %{cache_read_input_tokens: 0})

      assert CacheAttribution.cold_run("silent-loss-scope") == 1
    end

    test "the break path still works — the new arm did not replace it" do
      CacheAttribution.observe("silent-loss-scope", @fp, %{cache_read_input_tokens: 9_000})

      assert {:break, verdict} =
               CacheAttribution.observe("silent-loss-scope", @fp, %{cache_read_input_tokens: 0})

      assert is_binary(verdict)
    end
  end

  # ── 11. Real usage, written to a term nothing reads ───────────────────────

  describe "the CLI providers report the tokens they were told" do
    test "ClaudeCli publishes usage under the four key names Accounting reads" do
      :persistent_term.put(
        {ClaudeCli, :usage},
        %{
          "usage" => %{
            "input_tokens" => 1200,
            "output_tokens" => 340,
            "cache_read_input_tokens" => 900,
            "cache_creation_input_tokens" => 12
          },
          "total_cost_usd" => 0.0412
        }
      )

      usage = ClaudeCli.reported_usage()

      assert %{
               input_tokens: 1200,
               output_tokens: 340,
               cache_read_input_tokens: 900,
               cache_creation_input_tokens: 12
             } = usage

      # 1200 + 12 + 900. `:claude_cli` is in `@disjoint_prompt_slices`, so the
      # cache slices are ADDITIONAL to `input_tokens` rather than carved out of
      # them — the convention was already configured for a usage map that never
      # arrived. What matters is that the total is not 0.
      assert Accounting.effective_input_tokens(usage) == 2112,
             "a token count filed under any other key prices at $0.00 and makes " <>
               "max_budget_usd unenforceable"

      assert ClaudeCli.reported_cost() == 0.0412,
             "the CLI's own total_cost_usd is authoritative on a Max plan — an OSA-side " <>
               "estimate from a list rate card is not the same number"
    end

    test "Copilot's premium-request meter is not laundered into a token count" do
      :persistent_term.put({CopilotCli, :usage}, %{"premiumRequests" => 0.33})

      assert CopilotCli.reported_quota() == %{premium_requests: 0.33}

      assert CopilotCli.reported_usage() == nil,
             "Copilot bills in premium requests, not tokens. Synthesising a token count " <>
               "would be a fabricated measurement; reporting nil lets " <>
               "Accounting.report_unaccounted/2 say so honestly."
    end
  end

  # ── 12. A substring where a word was meant ────────────────────────────────

  describe "fast-mode tool selection matches words, not fragments" do
    test "a keyword does not fire from inside a longer word" do
      # `String.contains?/2` made "code" match *encode*, "test" match *latest*,
      # "git" match *digit*, "pr" match *print*. A phantom intent is not
      # harmless: `select_tools/2` unions the matched intents' tool lists and
      # then TRUNCATES to `Effort.tool_budget()`, so a false hit pushes real
      # tools off the end of the cap.
      assert FastPath.classify_intents("please encode the latest digit into a print expression") ==
               []
    end

    test "the words it was written for still match" do
      assert :code in FastPath.classify_intents("fix the bug in this code")
      assert :git in FastPath.classify_intents("show me the git diff")
      assert :search in FastPath.classify_intents("find where this is defined")
    end

    test "inflections are not the price of dropping fragments" do
      # The over-correction is as bad as the bug: a strict word-equality rule
      # loses `scheduler`, `tests`, `commits`, `files` — words users type
      # constantly — and a lost intent silently narrows the toolbox exactly the
      # way a phantom one does.
      assert :schedule in FastPath.classify_intents("fix the scheduler bug in cron_test.exs")
      assert :code in FastPath.classify_intents("update the failing tests")
      assert :git in FastPath.classify_intents("squash these commits")
    end

    test "a narrowed toolbox is announced" do
      # The only stage of `Loop.ToolFilter.filter/1` that logged nothing at all,
      # while dropping the majority of the tool surface on a keyword guess.
      Process.delete(:osa_fast_path_tools)
      Effort.set(:fast)

      tools =
        for name <- ~w(file_read file_write shell_execute browser computer_use memory_save) do
          %{name: name, description: name, parameters: %{}}
        end

      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          FastPath.select_tools(tools, %{
            messages: [%{role: "user", content: "fix the bug in this code"}]
          })
        end)

      assert log =~ "[FastPath]"
      assert log =~ "withheld"

      assert log =~ "[info]",
             "a tool the model was never offered looks exactly like a tool it chose not to call"
    end
  end

  # ── 13. The instrument, absent from the route it was measured on ──────────

  describe "every route that builds a cached prefix reports the cache read back" do
    # THE CLASS TEST for this sweep.
    #
    # `CacheAttribution` is the watchdog for a prompt cache that breaks or never
    # warms. It was wired into `anthropic.ex` (4 call sites) and nowhere else —
    # in particular NOT into the OpenAI-compatible route, which is where the
    # 92.8% hit rate was measured and where caching was dead for months. The
    # instrument built to catch exactly that failure was absent from the path
    # the failure was on, so it could not have reported it.
    #
    # This refuses the NEXT provider wired with a cache marker and no attributor,
    # which is a strictly better guarantee than three tests naming the three
    # routes that exist today.
    test "a provider that places a cache marker also hands its usage to CacheAttribution" do
      # Assembling one of these into a REQUEST is the trigger. Parsing a counter
      # off a response is not enough on its own — that is the previous ratchet's
      # question, and the two are different failures.
      # `cachedContent` must not match Gemini's RESPONSE-side
      # `cachedContentTokenCount`: parsing a counter is the previous ratchet's
      # question, and google.ex places no request-side marker at all.
      request_markers = [~r/cache_control/, ~r/cachePoint/, ~r/cachedContent(?!Token)/]

      # Each exemption is a module that helps BUILD a marked request but never
      # sees a response, so it has no usage to attribute and no scope to attach
      # it to. The provider module downstream of it is the one that must observe.
      #
      #   cache_attribution.ex — the attributor itself.
      #   prompt_cache.ex      — restructures the message list; the transport
      #                          that sends it (openai_compat.ex) observes.
      #   registry.ex          — decides whether marked blocks survive to the
      #                          wire; same reasoning.
      exempt = ~w(cache_attribution.ex prompt_cache.ex registry.ex)

      lib = Path.join(File.cwd!(), "lib/optimal_system_agent/providers")

      offenders =
        lib
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.reject(&(&1 in exempt))
        |> Enum.map(&{&1, File.read!(Path.join(lib, &1))})
        |> Enum.filter(fn {_name, src} ->
          Enum.any?(request_markers, &Regex.match?(&1, src)) and
            not String.contains?(src, "CacheAttribution.observe")
        end)
        |> Enum.map(&elem(&1, 0))

      assert offenders == [], """
      #{inspect(offenders)} assemble a request-side prompt-cache marker but never
      hand the resulting usage to `CacheAttribution.observe/3`.

      That route can break its cache, or never warm it at all, with nothing
      reporting either. It is the precise state the OpenRouter route was in while
      OSA paid the full uncached rate on a ~30k-token prefix every turn — the
      watchdog existed, was correct, and was wired only into the one route that
      was already working.
      """
    end

    test "the compat route names a cache that never warms" do
      # The cold-cache arm fires on this route now that it is called at all.
      # Synthetic: no OpenRouter credentials exist on this machine, so the usage
      # map is hand-built in the shape `OpenAICompat.parse_usage/1` produces.
      scope = "compat-cold-scope"
      CacheAttribution.reset(scope)
      on_exit(fn -> CacheAttribution.reset(scope) end)

      body = %{
        model: "anthropic/claude-sonnet-4.5",
        messages: [%{"role" => "user", "content" => "hi"}],
        tools: []
      }

      fp = CacheAttribution.fingerprint(body)

      results =
        for _ <- 1..3 do
          OpenAICompat.observe_cache(
            fp,
            %{input_tokens: 12_000, output_tokens: 40, cache_read_input_tokens: 0},
            session_id: scope
          )
        end

      assert Enum.any?(results, &match?({:cold, _}, &1)),
             "the compat route must be able to report a permanently cold cache — that is the " <>
               "reading nothing on this route could produce for months"
    end

    test "an ESTIMATED usage map is not fed to the attributor as a measurement" do
      # `estimate_usage_fallback/3` synthesises token counts for backends that
      # ignore `stream_options.include_usage` (several local Ollama builds).
      # Those maps carry no cache slice, so passing them through would report a
      # permanently cold cache on every such backend — a confident verdict drawn
      # from a measurement that was never taken, which is the same class of
      # error as the silence it replaced.
      scope = "compat-estimated-scope"
      CacheAttribution.reset(scope)
      on_exit(fn -> CacheAttribution.reset(scope) end)

      fp = CacheAttribution.fingerprint(%{model: "local", messages: [], tools: []})

      for _ <- 1..5 do
        assert OpenAICompat.observe_cache(
                 fp,
                 %{input_tokens: 900, output_tokens: 30, estimated: true},
                 session_id: scope
               ) == :ok
      end

      assert CacheAttribution.cold_run(scope) == 0,
             "an absent measurement must not accumulate as a zero one"
    end
  end

  # ── 14. A global switch enforced in one module ────────────────────────────

  describe "prompt_caching_enabled is global, as its name says" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :prompt_caching_enabled)
      on_exit(fn -> restore(:prompt_caching_enabled, prev) end)
      :ok
    end

    @cached_system [
      %{
        "type" => "text",
        "text" => String.duplicate("static base. ", 400),
        "cache_control" => %{"type" => "ephemeral"}
      },
      %{"type" => "text", "text" => "volatile tail: 12:04:11"}
    ]

    defp compat_messages do
      [
        %{role: "system", content: @cached_system},
        %{role: "user", content: "first"},
        %{role: "assistant", content: "ok"},
        %{role: "user", content: "second"}
      ]
    end

    test "the switch reaches the OpenRouter route, not only anthropic.ex" do
      # All five call sites lived inside `anthropic.ex`. Setting the flag false
      # therefore turned caching OFF on the native path — the one route that had
      # it — and left it fully ON for OpenRouter → Anthropic, which is the route
      # the hit rate was measured on. An operator disabling caching to isolate a
      # billing question got the exact opposite on the path that mattered.
      opts = [model: "anthropic/claude-sonnet-4.5"]

      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on = Registry.normalize_outbound_messages(compat_messages(), {:compat, :openrouter}, opts)

      assert marked_anywhere?(on),
             "with caching ON the compat route must still carry cache_control — this test is " <>
               "worthless if the marker was never there to begin with"

      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, false)
      off = Registry.normalize_outbound_messages(compat_messages(), {:compat, :openrouter}, opts)

      refute marked_anywhere?(off),
             "prompt_caching_enabled: false must leave the OpenRouter wire free of every " <>
               "marker, exactly as it already does for the native Anthropic path"
    end

    test "PromptCache.restructure/3 consults it, and says so once" do
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, false)
      Process.delete(:osa_prompt_cache_off)

      log =
        capture_info(fn ->
          assert PromptCache.restructure(compat_messages(), {:compat, :openrouter},
                   model: "anthropic/claude-sonnet-4.5"
                 ) == compat_messages()
        end)

      assert log =~ "[PromptCache]"

      assert log =~ "[info]",
             "a rolling breakpoint that was not placed is worth ~16 points of hit rate by " <>
               "PromptCache's own measured table; skipping it silently is how the last one hid"
    end

    defp marked_anywhere?(messages) do
      Enum.any?(messages, fn msg ->
        case Map.get(msg, :content) || Map.get(msg, "content") do
          parts when is_list(parts) ->
            Enum.any?(parts, fn p ->
              is_map(p) and (Map.has_key?(p, :cache_control) or Map.has_key?(p, "cache_control"))
            end)

          _ ->
            false
        end
      end)
    end
  end

  # ── 15. One minimum, three numbers ────────────────────────────────────────

  describe "the cacheable minimum is one named constant" do
    # CLASS TEST. 4,000 on the Anthropic system side, 4,500 on its tools-side
    # sibling, 4,500 again in Bedrock with a comment promising to hold it equal
    # by hand. A comment is not a mechanism, and three copies of one number is
    # a description of how they drift, not of how they stay equal.
    test "no provider restates the threshold as its own literal" do
      lib = Path.join(File.cwd!(), "lib/optimal_system_agent/providers")

      offenders =
        lib
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.reject(&(&1 == "prompt_cache.ex"))
        |> Enum.map(&{&1, File.read!(Path.join(lib, &1))})
        |> Enum.filter(fn {_name, src} ->
          # A module attribute or assignment whose VALUE is one of the drifted
          # figures, on a line that mentions caching. Prose and comments are not
          # the mechanism and are not matched.
          src
          |> String.split("\n")
          |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
          |> Enum.any?(&Regex.match?(~r/cache\w*\s+4_[05]00\b|@min_cacheable\w*\s+\d/i, &1))
        end)
        |> Enum.map(&elem(&1, 0))

      assert offenders == [], """
      #{inspect(offenders)} declare their own copy of the minimum cacheable
      payload size. There is one: `PromptCache.min_cacheable_bytes/0`.

      The figure is a measurement (4.1 bytes/token on the default 23-tool array,
      so 4,500 B ~ 1,100 tok, just clear of Anthropic's 1024-token floor). A
      second copy is a second calibration nobody will remember to redo.
      """
    end

    test "the three routes read the same number" do
      assert PromptCache.min_cacheable_bytes() == 4_500

      # Bedrock's marker and Anthropic's both sit on the same side of it.
      assert PromptCache.approx_tokens(PromptCache.min_cacheable_bytes()) >= 1024,
             "a threshold that does not clear the 1024-token floor buys a cache-write premium " <>
               "and no cache entry"
    end

    test "the Anthropic system side SAYS when it skips, like its tools sibling" do
      # The tools side reports `:below_min_cacheable` at :info with the numbers
      # that produced it. The system side made the same decision in total
      # silence — no marker, no error, no log, just a system prefix re-billed at
      # full rate every turn.
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)
      Process.delete(:osa_system_cache_decision)

      short = String.duplicate("x", PromptCache.min_cacheable_bytes() - 1)

      log =
        capture_info(fn ->
          body = OptimalSystemAgent.Providers.Anthropic.maybe_add_system(%{}, short)
          assert body.system == short, "an unmarkable prefix is sent as a plain string"
        end)

      assert log =~ "[Anthropic] system cache breakpoint NOT placed"
      assert log =~ "re-billed in full every turn"
      assert log =~ "[info]"
    end

    test "a prefix over the minimum is still marked" do
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :prompt_caching_enabled) end)

      long = String.duplicate("x", PromptCache.min_cacheable_bytes() + 1)
      body = OptimalSystemAgent.Providers.Anthropic.maybe_add_system(%{}, long)

      assert [%{cache_control: %{type: "ephemeral"}}] = body.system
    end
  end

  # ── 16. A rate card overruling the provider's own bill ────────────────────

  describe "the provider's own price wins over the rate card" do
    defp billing_state do
      %{
        session_id: "billing-#{System.unique_integer([:positive])}",
        provider: :claude_cli,
        model: "claude-sonnet-4-5",
        session_cost_usd: 0.0
      }
    end

    @cli_usage %{
      input_tokens: 1200,
      output_tokens: 340,
      cache_read_input_tokens: 900,
      cache_creation_input_tokens: 12
    }

    test "a CLI-reported cost replaces the estimate rather than adding to it" do
      estimate = Accounting.turn_cost(billing_state(), Accounting.normalize_usage(@cli_usage), [])

      assert estimate > 0.0,
             "this test is meaningless unless the rate card would have produced a number"

      priced =
        Accounting.record(billing_state(), @cli_usage, provider_cost_usd: 0.0412)

      assert priced.session_cost_usd == 0.0412,
             "the CLI's own total_cost_usd is the authoritative figure on a Max plan — the " <>
               "user runs one, so `tokens x list price` is not a rounding error here but a " <>
               "number that never matched the bill"

      refute_in_delta priced.session_cost_usd, 0.0412 + estimate, 1.0e-9
    end

    test "with no provider figure the rate card still prices the turn" do
      state = Accounting.record(billing_state(), @cli_usage, [])

      assert state.session_cost_usd > 0.0,
             "the override must not become a silent way to bill nothing"
    end

    test "the substitution is announced, not silent" do
      Process.delete(:osa_provider_cost_source)

      log =
        capture_info(fn ->
          Accounting.record(billing_state(), @cli_usage, provider_cost_usd: 0.0412)
        end)

      assert log =~ "[Accounting]"
      assert log =~ "total_cost_usd"

      assert log =~ "[info]",
             "the one place a session's cost stops coming from OSA's price table must be " <>
               "visible; a silent substitution is indistinguishable from a pricing bug"
    end

    # ── The sixth class ratchet ───────────────────────────────────────────
    #
    # Three pricing defects shipped in one night, and they share a shape that
    # none of the per-model tests above can catch:
    #
    #   * `glm-5.2:cloud` carried GLM-4.7's rate            (under 2.4x)
    #   * `anthropic/claude-opus-5` missed the exact table on its vendor
    #     prefix, matched the `"claude-opus"` substring, and billed at Claude 3
    #     Opus rates                                         (over 3.000x)
    #   * `claude-sonnet-5` carried the list rate through an introductory
    #     period                                             (over 1.500x)
    #
    # In all three `Pricing.confidence/1` said `:exact`. That is the defect:
    # a wrong number reached via an "exact" path never touches the `@families`
    # guess that would have warned, so the loudness added there protects only
    # the models that were never the problem.
    #
    # The invariant that would have caught all three: **every model a provider
    # surface can actually offer prices at the rate its OWN catalog publishes,
    # through the spellings a gateway actually sends, and reports `:exact`.**
    # Catalog drift, a vendor-prefix miss, and a routing-suffix miss all break
    # it. So does a new catalog nobody wired into `Pricing`.
    #
    # What it cannot catch, stated so nobody reads more into a green run: it
    # compares OSA against OSA. A catalog whose number disagrees with the
    # vendor's published rate is exactly as green as one that agrees — that
    # check needs the vendor's page, not the test suite.
    @priced_catalogs [
      OptimalSystemAgent.Providers.AnthropicModels,
      OptimalSystemAgent.Providers.OpenAIModels,
      OptimalSystemAgent.Providers.XAIModels,
      OptimalSystemAgent.Providers.ZaiModels,
      OptimalSystemAgent.Providers.GoogleModels,
      OptimalSystemAgent.Providers.DeepSeekModels,
      OptimalSystemAgent.Providers.MistralModels,
      OptimalSystemAgent.Providers.OllamaCloud,
      # A RESELLER's rate card, and the reason the ratchet had to learn about
      # namespaced ids at all. api.uncensored.com relists the catalogs above
      # under their own vendor ids at its own margin, so `claude-opus-5` there
      # billed Anthropic's {5.00, 25.00} against a real {6.00, 30.00} — and,
      # like the three defects this describe block was written for, said
      # `:exact` while doing it.
      OptimalSystemAgent.Providers.UncensoredModels
    ]

    # The last date on which every catalog's `:pricing` is, by definition, the
    # rate in force — derived from the schedules rather than hardcoded, so
    # adding a dated rate cannot silently invalidate the baseline and no
    # assertion here expires with the calendar.
    # Windowed cards count here too, and for a sharper reason than schedules do:
    # past a window's effective instant a bare Date names no tier at all, so
    # `:pricing` is not merely superseded, it is unanswerable from a date. Fold
    # both in and the baseline stays honest as either kind of card is added.
    defp pricing_baseline_date do
      schedule_dates =
        Pricing.pricing_schedules()
        |> Enum.flat_map(fn {_id, entries} -> Enum.map(entries, fn {d, _r} -> d end) end)

      window_dates =
        Pricing.pricing_windows()
        |> Enum.map(fn {_id, w} -> DateTime.to_date(w.effective_from) end)

      (schedule_dates ++ window_dates)
      |> Enum.min_by(&Date.to_gregorian_days/1, fn -> ~D[2099-01-01] end)
      |> Date.add(-1)
    end

    # The decorations a gateway puts on an id. OpenRouter sends `vendor/id`;
    # `:free`/`:nitro` are routing directives, not identity. Ids that already
    # carry a `:` tag (`glm-5.2:cloud`) are left alone — a second colon is not
    # a spelling anything emits.
    #
    # An id that ALREADY carries a `/` segment is a namespaced reseller key
    # (`uncensored/claude-opus-5`), not a bare model id, and is not re-prefixed:
    # `vendor/uncensored/claude-opus-5` is a string nothing emits, and
    # `lookup_keys/1` would strip it down to the bare `claude-opus-5` and answer
    # with the upstream VENDOR's rate — turning a spelling no gateway sends into
    # a failure this ratchet cannot act on.
    defp gateway_spellings(id) do
      base = if String.contains?(id, "/"), do: [id], else: [id, "vendor/" <> id]
      if String.contains?(id, ":"), do: base, else: base ++ Enum.map(base, &(&1 <> ":free"))
    end

    test "every offerable priced model reaches its own catalog's rate, at :exact" do
      on = pricing_baseline_date()

      failures =
        for mod <- @priced_catalogs,
            {id, catalog_rate} <- mod.pricing(),
            spelling <- gateway_spellings(id),
            got = Pricing.rates(spelling, on),
            conf = Pricing.confidence(spelling, on),
            got != catalog_rate or conf != :exact do
          "  #{inspect(spelling)} (#{inspect(mod)}) -> #{inspect(got)} / #{conf}, " <>
            "catalog publishes #{inspect(catalog_rate)}"
        end

      assert failures == [], """
      #{length(failures)} offerable model(s) do not price at their own catalog's rate:

      #{Enum.join(failures, "\n")}

      Each line is a model OSA will happily run and bill at a number its own
      source of truth disagrees with — the shape that produced a 3.000x
      over-report (claude-opus-5 via its vendor prefix), a 2.4x under-report
      (glm-5.2:cloud), and a 1.500x over-report (claude-sonnet-5 on list
      price). A `:estimated` here means the id fell through to the
      `@families` substring guess; a mismatched rate means the exact table has
      drifted from the catalog it is supposed to mirror.

      Fix the catalog or the lookup path — do not add the id to the exact map
      by hand, which is how these tables drift apart in the first place.
      """
    end

    test "a dated rate changes itself on its date, in both directions" do
      # The mechanism, pinned with injected dates so the test never expires.
      # A rate whose only clock is Date.utc_today/0 cannot be tested on both
      # sides of its own boundary, and an assertion that goes red on a calendar
      # date is a defect, not a guard.
      assert Pricing.pricing_schedules() != %{},
             "this ratchet is vacuous with no scheduled rates in the tree"

      for {id, entries} <- Pricing.pricing_schedules(),
          {effective_from, scheduled} <- entries do
        day_before = Date.add(effective_from, -1)

        before_rate = Pricing.rates(id, day_before)

        assert before_rate != scheduled,
               "#{id}: the scheduled rate #{inspect(scheduled)} is already in force the day " <>
                 "before #{effective_from} — the entry is a no-op and will be forgotten"

        assert Pricing.rates(id, effective_from) == scheduled,
               "#{id}: rate did not change on #{effective_from}"

        assert Pricing.confidence(id, effective_from) == :exact,
               "#{id}: a published rate with a published start date is not a guess"

        # And through the spelling a gateway sends — the vendor-prefix miss is
        # the whole reason lookup_keys/1 exists.
        assert Pricing.rates("vendor/" <> id, effective_from) == scheduled,
               "#{id}: the schedule does not survive a vendor prefix"
      end
    end

    # ── The seventh class: a rate that is a function of the HOUR ──────────
    #
    # DeepSeek moved to peak/off-peak on 2026-08-16 and OSA under-billed it by
    # 1.6x–4.7x, because a model with two published prices had one number
    # encoded for it. The failure a single-value catalog cannot even express:
    # there IS no rate to check, only a rate-at-an-instant.
    #
    # Same honesty caveat as the ratchet above — this compares OSA to OSA. It
    # cannot know DeepSeek's real hours. What it CAN guarantee is that whatever
    # hours a catalog claims, both tiers are actually reachable through the
    # spellings a gateway sends, that they differ, that neither leaks backwards
    # past the card's effective instant, and that a caller who cannot name the
    # hour is never handed an `:exact`.
    #
    # Every instant below is INJECTED. Nothing here reads the wall clock: a
    # peak-hours assertion that passes only between 01:00 and 04:00 UTC is not
    # a guard, it is a scheduled outage.
    defp an_hour_in(peak_hours), do: peak_hours |> List.first() |> elem(0)

    defp an_hour_outside(peak_hours) do
      Enum.find(0..23, fn h ->
        not Enum.any?(peak_hours, fn {from, until} -> h >= from and h < until end)
      end)
    end

    defp at_hour(%DateTime{} = day, hour) do
      %{day | hour: hour, minute: 0, second: 0, microsecond: {0, 0}}
    end

    test "a windowed rate resolves to BOTH of its tiers, at the hours it publishes" do
      assert Pricing.pricing_windows() != %{},
             "this ratchet is vacuous with no time-varying rates in the tree"

      for {id, window} <- Pricing.pricing_windows() do
        # Well after the card lands, so nothing here depends on the boundary day.
        day = DateTime.add(window.effective_from, 30, :day)
        peak_at = at_hour(day, an_hour_in(window.peak_hours))
        off_at = at_hour(day, an_hour_outside(window.peak_hours))

        assert window.peak.pricing != window.off_peak.pricing,
               "#{id}: both tiers carry the same rate — the window is a no-op and the " <>
                 "whole mechanism could be deleted without changing a bill"

        assert Pricing.rates(id, peak_at) == window.peak.pricing,
               "#{id}: peak hour #{peak_at.hour}:00 UTC did not resolve to the peak tier"

        assert Pricing.rates(id, off_at) == window.off_peak.pricing,
               "#{id}: off-peak hour #{off_at.hour}:00 UTC did not resolve to the off-peak tier"

        for {label, at} <- [peak: peak_at, off_peak: off_at] do
          assert Pricing.confidence(id, at) == :exact,
                 "#{id}: #{label} is a published rate at a known hour, not a guess"

          # The vendor-prefix miss is what billed Opus 5 at 3x. A new dimension
          # that only works on the bare id reinstates it.
          assert Pricing.rates("vendor/" <> id, at) == Pricing.rates(id, at),
                 "#{id}: the window does not survive a vendor prefix at #{label}"
        end

        # Half-open [from, until): the first hour is in, the closing hour is out.
        # Stated once in the catalog; pinned once here.
        for {from, until} <- window.peak_hours do
          assert Pricing.rates(id, at_hour(day, from)) == window.peak.pricing,
                 "#{id}: #{from}:00 is the first peak hour and must bill as peak"

          if until <= 23 do
            assert Pricing.rates(id, at_hour(day, until)) == window.off_peak.pricing,
                   "#{id}: #{until}:00 closes the window and must bill as off-peak"
          end
        end

        # Nothing leaks backwards. A turn taken a second before the card lands
        # is billed at the rate it was actually charged, forever.
        one_second_before = DateTime.add(window.effective_from, -1, :second)

        assert Pricing.rates(id, one_second_before) not in [
                 window.peak.pricing,
                 window.off_peak.pricing
               ],
               "#{id}: the new card is already in force before #{window.effective_from} — " <>
                 "history re-prices itself, which is the one thing this design forbids"

        # An unnamed hour is an unknown, not a coin flip. It bills at the peak
        # tier (never under-state) and says so.
        a_date = DateTime.to_date(day)

        assert Pricing.rates(id, a_date) == window.peak.pricing,
               "#{id}: a date-only clock must not under-state a time-varying rate"

        assert Pricing.confidence(id, a_date) == :estimated,
               "#{id}: a rate resolved without the hour it depends on is not :exact"
      end
    end

    test "a windowed cache-read rate moves with its own tier" do
      for {id, window} <- Pricing.pricing_windows(),
          not is_nil(window.peak.cache_read) do
        day = DateTime.add(window.effective_from, 30, :day)
        peak_at = at_hour(day, an_hour_in(window.peak_hours))
        off_at = at_hour(day, an_hour_outside(window.peak_hours))

        assert Pricing.cache_read_rate(id, peak_at) == {window.peak.cache_read, :published}
        assert Pricing.cache_read_rate(id, off_at) == {window.off_peak.cache_read, :published}
      end
    end

    # ── The eighth class: a published number that billing throws away ─────
    #
    # `cache_read_rate/1` sat in the xAI and Z.ai catalogs, correct and
    # consumed by nothing, while `Pricing` billed every cache read at a flat
    # `input * 0.1`. grok-4.6 under-billed by 2.5x, glm-5.2 by 1.86x, and
    # deepseek-v4-flash OVER-billed by 5x — all reported `:exact`, because the
    # RATE was exact and nobody was asking about the cache column.
    #
    # A catalog carrying the right answer that billing ignores is worse than no
    # catalog: it looks like coverage.
    @cache_read_catalogs [
      OptimalSystemAgent.Providers.XAIModels,
      OptimalSystemAgent.Providers.ZaiModels,
      OptimalSystemAgent.Providers.DeepSeekModels
    ]

    test "a published cache-read rate is billed, never the flat multiplier" do
      on = pricing_baseline_date()

      failures =
        for mod <- @cache_read_catalogs,
            %{id: id} = m <- mod.models(),
            published = mod.cache_read_rate(id),
            not is_nil(published),
            spelling <- gateway_spellings(id),
            got = Pricing.cache_read_rate(spelling, on),
            got != {published, :published} do
          "  #{inspect(spelling)} (#{inspect(mod)}) -> #{inspect(got)}, " <>
            "catalog publishes #{published} (model #{inspect(m.name)})"
        end

      assert failures == [], """
      #{length(failures)} model(s) publish a cached-input rate that billing does not use:

      #{Enum.join(failures, "\n")}

      A `:multiplier` here means the flat `input * 0.1` fallback fired for a
      model whose vendor quotes a real number — the shape that under-billed
      grok-4.6 cache reads by 2.5x while `confidence/1` said `:exact`.
      """
    end

    test "the flat multiplier remains the documented fallback, and says so" do
      # Anthropic publishes no separate cached-input column; 0.1x IS its
      # published ratio. The fallback is not a bug, it is the other branch —
      # what matters is that a caller can tell the two apart.
      assert {rate, :multiplier} = Pricing.cache_read_rate("claude-3-5-sonnet")
      assert_in_delta rate, 0.30, 0.000_001
      assert Pricing.cache_read_confidence("claude-3-5-sonnet") == :multiplier

      assert Pricing.cache_read_confidence("grok-4.6") == :published
      assert Pricing.cache_read_confidence("no-such-model-anywhere") == :unknown
    end

    test "a cache-heavy turn is billed at the published rate, not input * 0.1" do
      # grok-4.6: $2.00 input, $0.50 published cache read. The multiplier would
      # say $0.20 — 2.5x low on every cached token, which on a long agentic
      # session is most of the prompt.
      usage = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 1_000_000
      }

      assert_in_delta Pricing.cost("grok-4.6", usage), 0.50, 0.000_001

      refute_in_delta Pricing.cost("grok-4.6", usage),
                      0.20,
                      0.000_001,
                      "cache reads fell back to the flat multiplier for a model that publishes a rate"
    end

    test "a recorded turn does not re-price itself as the clock moves" do
      # The failure this guards is subtle and worse than under-billing: view a
      # session at 02:00 UTC and again at 05:00 and get two different numbers
      # for the same finished turn. Stamping the request instant onto the usage
      # map is what makes the price a property of the turn rather than of the
      # viewing.
      [{id, window} | _] = Enum.to_list(Pricing.pricing_windows())
      day = DateTime.add(window.effective_from, 30, :day)
      issued_at = at_hour(day, an_hour_in(window.peak_hours))
      viewed_later = at_hour(day, an_hour_outside(window.peak_hours))

      usage = %{input_tokens: 1_000_000, output_tokens: 0, requested_at: issued_at}

      priced_then = Pricing.cost(id, usage, issued_at)
      priced_now = Pricing.cost(id, usage)
      priced_from_a_different_hour = Pricing.cost(id, usage, viewed_later)

      assert priced_then == priced_now,
             "#{id}: usage carrying :requested_at re-priced itself against the wall clock"

      # And the explicit argument still wins, for the caller who really does
      # mean "what would this have cost at that other hour".
      refute priced_from_a_different_hour == priced_then

      # Without the stamp there is nothing to be stable against, and the
      # docstring says so rather than pretending otherwise.
      unstamped = Map.delete(usage, :requested_at)

      assert Pricing.cost(id, unstamped, issued_at) == priced_then
    end

    test "Copilot's premium requests accumulate as themselves, not as dollars" do
      # `:copilot_cli` is in NEITHER prompt-slice list, deliberately: it reports
      # no tokens, so it has no slice convention to belong to. That is not a gap
      # to be closed.
      state =
        Accounting.record(billing_state(), nil, provider_quota: %{premium_requests: 0.33})

      assert state.session_premium_requests == 0.33
      assert state.session_cost_usd == 0.0, "a premium request is not a dollar figure"

      state2 = Accounting.record(state, nil, provider_quota: %{premium_requests: 0.33})
      assert state2.session_premium_requests == 0.66
    end
  end
end
