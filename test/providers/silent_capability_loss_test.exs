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
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Providers.Bedrock
  alias OptimalSystemAgent.Providers.Cohere
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
      assert reported = Observability.current_reasoning(%{provider: :google, model: "gemini-2.5-flash"})
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

      with_model = PromptCache.restructure(messages, {:compat, :openrouter}, model: "anthropic/claude-opus-5")
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
          ["-c", ~s(grep -rn "function_exported?" lib --include='*.ex' | grep -vc "Code.ensure_loaded")],
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
  end
end
