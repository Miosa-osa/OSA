defmodule OptimalSystemAgent.Providers.EffortThinkingMatrixTest do
  @moduledoc """
  W4 — the effort × provider thinking matrix.

  Verifies that every effort tier (fast / medium / high / xhigh / ultra, plus
  the `off` wire value) maps to the correct thinking parameter on each provider,
  and that a corrupt / unknown persisted effort never crashes any provider path
  (it falls back to `:medium` via `Effort.get/1`).

  Expected matrix (tier → provider param):

      tier    anthropic-adaptive           anthropic-budget    openai (reasoning)  gemini-2.5      ollama
              (4.6+, Claude 5)             (haiku-4-5, older)
      ----    -------------------------    -----------------   -----------------   ------------    ------
      fast    (no block — fast_mode)/low   (none — fast_mode)  reasoning=low       (none, budget0) no-op
      medium  adaptive + effort=medium     enabled/5000        reasoning=medium    budget 5000     no-op
      high    adaptive + effort=high       enabled/10000       reasoning=high      budget 10000    no-op
      xhigh   adaptive + effort=xhigh      enabled/32000       reasoning=high      budget 32000    no-op
      ultra   adaptive + effort=max        enabled/64000       reasoning=high      budget 64000    no-op
      off     (none)                       (none)              (omit)              (none, budget0) no-op

  The anthropic split is by MODEL, not by opus-vs-sonnet. Anthropic removed the
  fixed thinking budget on the Claude 5 family and on Opus 4.7/4.8: sending
  `{type: "enabled", budget_tokens: N}` to those models is a hard 400. Depth on
  them is steered by `output_config.effort`, not a token count — so every tier
  maps to plain `adaptive` and the effort tier rides the separate effort param.

  **That effort param was sent from nowhere until v1.0.99**, which made the whole
  ladder inert on every current Claude model: the `adaptive` column above is
  identical in all five rows, so `/effort fast` and `/effort ultra` produced
  byte-identical requests. The `+ effort=` half of that column is the fix; the
  `openai (reasoning)` column had the same defect from the other direction (a
  hardcoded \"medium\" on the no-opt branch).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Providers.{Anthropic, Google, Ollama, OpenAICompat}

  @opus "claude-opus-4-8"
  @sonnet "claude-sonnet-4-6"
  # Haiku 4.5 is the one current model that still speaks the fixed-budget
  # thinking dialect; every 4.6+ model takes adaptive only.
  @haiku "claude-haiku-4-5"
  @openai_model "o3-mini"
  @gemini_thinking "gemini-2.5-pro"
  @gemini_flat "gemini-2.0-flash"
  @ollama_flat "llama3.2:latest"

  setup do
    prev = %{
      thinking_enabled: Application.get_env(:optimal_system_agent, :thinking_enabled),
      default_provider: Application.get_env(:optimal_system_agent, :default_provider),
      effort_level: Application.get_env(:optimal_system_agent, :effort_level),
      ollama_think: Application.get_env(:optimal_system_agent, :ollama_think),
      session: session_effort()
    }

    Application.put_env(:optimal_system_agent, :thinking_enabled, true)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

    on_exit(fn ->
      restore_session_effort(prev.session)
      restore(:thinking_enabled, prev.thinking_enabled)
      restore(:default_provider, prev.default_provider)
      restore(:effort_level, prev.effort_level)
      restore(:ollama_think, prev.ollama_think)
    end)

    :ok
  end

  # ── Anthropic ──────────────────────────────────────────────────────────────

  describe "anthropic — opus (adaptive below ultra, enabled+64k at ultra)" do
    for tier <- [:medium, :high, :xhigh] do
      test "opus at #{tier} → adaptive thinking" do
        Effort.set(unquote(tier))
        cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @opus})
        assert cfg == %{type: "adaptive"}

        body = Anthropic.maybe_add_thinking(%{model: @opus}, cfg)
        assert body.thinking == %{type: "adaptive"}
      end
    end

    test "opus at ultra → STILL adaptive (budget_tokens is a 400 on this model)" do
      Effort.set(:ultra)
      cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @opus})
      assert cfg == %{type: "adaptive"}

      body = Anthropic.maybe_add_thinking(%{model: @opus}, cfg)
      assert body.thinking == %{type: "adaptive"}
    end

    test "opus at fast → no thinking block" do
      Effort.set(:fast)
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @opus}) == nil
    end
  end

  describe "anthropic — adaptive-thinking models (the Claude 5 family, 4.6+)" do
    for tier <- [:medium, :high, :xhigh, :ultra] do
      test "sonnet at #{tier} → adaptive (never budget_tokens)" do
        Effort.set(unquote(tier))
        cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet})
        assert cfg == %{type: "adaptive"}

        body = Anthropic.maybe_add_thinking(%{model: @sonnet}, cfg)
        assert body.thinking == %{type: "adaptive"}
      end
    end

    for model <- ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"] do
      test "#{model} never receives budget_tokens at any tier" do
        for tier <- [:medium, :high, :xhigh, :ultra] do
          Effort.set(tier)
          cfg = LLMClient.thinking_config(%{provider: :anthropic, model: unquote(model)})
          assert cfg == %{type: "adaptive"}
        end
      end
    end

    test "sonnet at fast → no thinking block" do
      Effort.set(:fast)
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet}) == nil
    end
  end

  describe "anthropic — budget-thinking models (Haiku 4.5 and older)" do
    for {tier, budget} <- [{:medium, 5_000}, {:high, 10_000}, {:xhigh, 32_000}, {:ultra, 64_000}] do
      test "haiku at #{tier} → enabled with budget #{budget}" do
        Effort.set(unquote(tier))
        cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @haiku})
        assert cfg == %{type: "enabled", budget_tokens: unquote(budget)}

        body = Anthropic.maybe_add_thinking(%{model: @haiku}, cfg)
        assert body.thinking == %{type: "enabled", budget_tokens: unquote(budget)}
      end
    end
  end

  describe "normalize_thinking/2 — the provider-level 400 guard" do
    test "coerces a stray budget config to adaptive on an adaptive-only model" do
      stray = %{type: "enabled", budget_tokens: 32_000}

      for model <- ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", @sonnet, @opus] do
        assert Anthropic.normalize_thinking(stray, model) == %{type: "adaptive"}
      end
    end

    test "leaves a budget config intact on a budget model" do
      stray = %{type: "enabled", budget_tokens: 32_000}
      assert Anthropic.normalize_thinking(stray, @haiku) == stray
    end

    test "nil stays nil" do
      assert Anthropic.normalize_thinking(nil, @sonnet) == nil
    end
  end

  # ── OpenAI (reasoning_effort: fast→low, xhigh/ultra→high, off→omit) ──────────

  describe "openai — reasoning_effort mapping per tier" do
    for {tier, expected} <- [
          {:fast, "low"},
          {:medium, "medium"},
          {:high, "high"},
          {:xhigh, "high"},
          {:ultra, "high"}
        ] do
      test "#{tier} → reasoning_effort=#{expected}" do
        body = OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: unquote(tier))
        assert body.reasoning_effort == unquote(expected)
      end
    end

    test "off → reasoning_effort omitted entirely" do
      body = OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: "off")
      refute Map.has_key?(body, :reasoning_effort)
    end

    test "no reasoning_effort opt follows the LIVE setting, not a constant" do
      # This assertion used to read `== "medium"` with no effort set, which
      # locked in the defect: `maybe_add_reasoning/3` hardcoded "medium" on the
      # nil branch, and NOTHING on the normal turn path passes
      # `:reasoning_effort`. So every o-series / GPT-5.x request went out at
      # "medium" no matter what `/effort` said — the ladder was inert on this
      # transport exactly as it was on Anthropic.
      Effort.set(:ultra)
      assert OpenAICompat.build_stream_body(@openai_model, [], []).reasoning_effort == "high"

      Effort.set(:fast)
      assert OpenAICompat.build_stream_body(@openai_model, [], []).reasoning_effort == "low"

      Effort.set(:medium)
      assert OpenAICompat.build_stream_body(@openai_model, [], []).reasoning_effort == "medium"
    end

    test "a non-reasoning model still gets no reasoning_effort at any tier" do
      Effort.set(:ultra)
      body = OpenAICompat.build_stream_body("gpt-4o-mini", [], [])
      refute Map.has_key?(body, :reasoning_effort)
    end
  end

  # ── Anthropic effort (output_config.effort — the depth carrier) ─────────────

  describe "anthropic — output_config.effort per tier" do
    # The thinking BLOCK is identical at every tier on an adaptive model
    # (asserted above). Depth rides entirely on this separate field, which OSA
    # sent from nowhere — so the ladder was a no-op on every current Claude
    # model. Full coverage lives in `anthropic_effort_test.exs`; this row keeps
    # the matrix honest.
    for {tier, wire} <- [
          {:fast, "low"},
          {:medium, "medium"},
          {:high, "high"},
          {:xhigh, "xhigh"},
          {:ultra, "max"}
        ] do
      test "#{tier} → output_config.effort=#{wire}" do
        Effort.set(unquote(tier))
        assert Anthropic.build_output_config(@opus, []) == %{effort: unquote(wire)}
      end
    end

    test "haiku takes budget_tokens instead and gets no output_config" do
      Effort.set(:ultra)
      assert Anthropic.build_output_config(@haiku, []) == nil

      assert LLMClient.thinking_config(%{provider: :anthropic, model: @haiku}) ==
               %{type: "enabled", budget_tokens: 64_000}
    end
  end

  # ── Gemini (thinking_budget → thinkingConfig; 0/off → omit) ──────────────────

  describe "gemini — thinking_budget mapping per tier" do
    for {tier, budget} <- [{:medium, 5_000}, {:high, 10_000}, {:xhigh, 32_000}, {:ultra, 64_000}] do
      test "#{tier} (budget #{budget}) → thinkingConfig with that budget" do
        cfg = Google.build_thinking_config(@gemini_thinking, thinking_budget: unquote(budget))
        assert cfg == %{thinkingConfig: %{thinkingBudget: unquote(budget)}}
      end
    end

    test "fast / off (budget 0) → no thinkingConfig" do
      assert Google.build_thinking_config(@gemini_thinking, thinking_budget: 0) == %{}
    end

    test "non-thinking model never gets a thinkingConfig, any budget" do
      assert Google.build_thinking_config(@gemini_flat, thinking_budget: 64_000) == %{}
    end

    test "non-integer budget is a no-op (never emits thinkingBudget: nil)" do
      assert Google.build_thinking_config(@gemini_thinking, thinking_budget: nil) == %{}
    end
  end

  # ── Gemini 3.x (thinkingLevel enum, NOT a token budget) ─────────────────────

  describe "gemini 3.x — effort maps to thinkingLevel, not thinkingBudget" do
    @gemini3 "gemini-3.6-flash"
    @gemini3_pro "gemini-3.1-pro-preview"

    # The regression this locks down: the old predicate was
    # `String.contains?(name, "2.5")`. When the default moved to
    # gemini-3.6-flash it went false, so OSA sent NO thinking config at all and
    # the whole effort ladder was a silent no-op on Google.
    test "the current default model gets a thinking config at all" do
      cfg = Google.build_thinking_config(@gemini3, reasoning_effort: "high")
      refute cfg == %{}, "gemini-3.6-flash must not fall through as a non-thinking model"
    end

    for {effort, level} <- [
          {"fast", "minimal"},
          {"low", "low"},
          {"medium", "medium"},
          {"high", "high"},
          {"xhigh", "high"},
          {"ultra", "high"}
        ] do
      test "effort #{effort} → thinkingLevel #{level}" do
        assert Google.build_thinking_config(@gemini3, reasoning_effort: unquote(effort)) ==
                 %{thinkingLevel: unquote(level)}
      end
    end

    test "never emits a thinkingBudget for a 3.x model" do
      # thinkingLevel and thinkingBudget are MUTUALLY EXCLUSIVE — sending both
      # is a hard request error.
      cfg =
        Google.build_thinking_config(@gemini3, thinking_budget: 32_000, reasoning_effort: "high")

      refute Map.has_key?(cfg, :thinkingConfig)
      assert Map.has_key?(cfg, :thinkingLevel)
    end

    test "off clamps to the model floor rather than disabling — 3.x cannot disable thinking" do
      assert Google.build_thinking_config(@gemini3, reasoning_effort: "off") ==
               %{thinkingLevel: "minimal"}
    end

    test "Pro has no minimal level, so off/fast clamps UP to low" do
      # gemini-3.1-pro-preview accepts only low/medium/high. Emitting "minimal"
      # would be rejected by the API.
      assert Google.build_thinking_config(@gemini3_pro, reasoning_effort: "off") ==
               %{thinkingLevel: "low"}

      assert Google.build_thinking_config(@gemini3_pro, reasoning_effort: "fast") ==
               %{thinkingLevel: "low"}
    end

    test "the legacy 2.5 dialect still emits a token budget" do
      # 2.5 is no longer offered but a pinned config can still name it, and it
      # takes the OTHER dialect.
      assert Google.build_thinking_config(@gemini_thinking, thinking_budget: 5_000) ==
               %{thinkingConfig: %{thinkingBudget: 5_000}}
    end
  end

  # ── DeepSeek V4 (thinking moved from a model id to a request parameter) ──────

  describe "deepseek v4 — thinking is a request parameter" do
    alias OptimalSystemAgent.Providers.DeepSeekModels

    @ds_flash "deepseek-v4-flash"
    @ds_pro "deepseek-v4-pro"

    test "reasoning_model?/1 is true for V4 even though the id is not deepseek-reasoner" do
      # The old code compared `name == "deepseek-reasoner"`, so V4 models
      # silently lost the 600s reasoning timeout.
      assert OpenAICompat.reasoning_model?(@ds_flash)
      assert OpenAICompat.reasoning_model?(@ds_pro)
    end

    test "the request body carries a thinking object" do
      body = OpenAICompat.build_stream_body(@ds_flash, [], reasoning_effort: "high")
      assert body["thinking"] == %{"type" => "enabled", "reasoning_effort" => "high"}
      assert body["reasoning_effort"] == "high"
    end

    test "off sends type disabled EXPLICITLY — omitting it would leave thinking on" do
      # DeepSeek defaults thinking.type to "enabled", so an absent object is ON.
      assert DeepSeekModels.thinking_params(@ds_flash, "off") ==
               %{"thinking" => %{"type" => "disabled"}}
    end

    test "pro rejects low, so a low effort clamps up to high" do
      assert %{"reasoning_effort" => "high"} = DeepSeekModels.thinking_params(@ds_pro, "low")
      assert %{"reasoning_effort" => "low"} = DeepSeekModels.thinking_params(@ds_flash, "low")
    end

    test "OSA medium maps to high — DeepSeek has no medium" do
      assert %{"reasoning_effort" => "high"} = DeepSeekModels.thinking_params(@ds_flash, "medium")
      assert %{"reasoning_effort" => "max"} = DeepSeekModels.thinking_params(@ds_flash, "ultra")
    end

    test "the DeepSeek effort overwrites the generic medium a reasoning model would get" do
      # maybe_add_reasoning/3 sets "medium", which DeepSeek does not accept, so
      # the provider-specific step must run last and win.
      body = OpenAICompat.build_stream_body(@ds_flash, [], [])
      assert body["reasoning_effort"] in ["low", "high", "max"]
    end

    test "a non-DeepSeek model is untouched" do
      assert DeepSeekModels.thinking_params(@openai_model, "high") == %{}
      body = OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: "high")
      refute Map.has_key?(body, "thinking")
    end
  end

  # ── Ollama (no thinking wiring → clean no-op, never crash) ───────────────────

  describe "ollama — clean no-op regardless of effort tier" do
    for tier <- [:fast, :medium, :high, :xhigh, :ultra] do
      test "effort #{tier} leaves a non-thinking-model body untouched (no crash)" do
        Effort.set(unquote(tier))
        base = %{model: @ollama_flat, messages: []}
        assert Ollama.apply_think(base, @ollama_flat, []) == base
      end
    end

    test "LOCALLY served reasoning model defaults think:false (unbounded-stall guard)" do
      Application.delete_env(:optimal_system_agent, :ollama_think)
      body = Ollama.apply_think(%{}, "kimi-k2", [])
      assert body["think"] == false
    end

    test "CLOUD served reasoning model defaults think:true (stall risk is the provider's)" do
      Application.delete_env(:optimal_system_agent, :ollama_think)
      body = Ollama.apply_think(%{}, "glm-5.2:cloud", [])
      assert body["think"] == true
    end
  end

  # ── off tier: no thinking block sent ANYWHERE ────────────────────────────────

  describe "off tier disables thinking across all providers" do
    test "no provider emits a thinking parameter for off" do
      # off normalizes to :fast (lowest / disabled)
      Effort.set("off")

      # anthropic: fast_mode → thinking_config nil
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @opus}) == nil
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet}) == nil

      # openai: explicit off omits reasoning_effort
      oa = OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: "off")
      refute Map.has_key?(oa, :reasoning_effort)

      # gemini: budget 0 → no thinkingConfig
      assert Google.build_thinking_config(@gemini_thinking, thinking_budget: 0) == %{}

      # ollama: no-op
      assert Ollama.apply_think(%{}, @ollama_flat, []) == %{}
    end
  end

  # ── Invalid / unknown persisted effort → :medium fallback, no crash ──────────

  describe "invalid persisted effort falls back to :medium, no provider crashes" do
    setup do
      # Simulate a corrupt persisted value with no session override so
      # Effort.current/0 cascades to the (garbage) app-env value.
      clear_session_effort()
      Application.put_env(:optimal_system_agent, :effort_level, "banana-nonsense")
      :ok
    end

    test "Effort.get / current / thinking_budget fall back to :medium config" do
      assert Effort.current() == "banana-nonsense"
      # get/1 normalizes-then-defaults to the medium level map
      assert Effort.get("banana-nonsense").label == "medium"
      assert Effort.thinking_budget() == 5_000
    end

    test "anthropic provider path does not crash and uses the medium budget" do
      # opus: rank(unknown) = -1, so NOT at_least ultra → adaptive
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @opus}) ==
               %{type: "adaptive"}

      # sonnet-4-6 is adaptive-only, so a corrupt effort cannot produce a
      # budget_tokens payload for it either.
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet}) ==
               %{type: "adaptive"}

      # Haiku still takes a budget, and falls back to the medium one.
      cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @haiku})
      assert cfg == %{type: "enabled", budget_tokens: 5_000}
      assert Anthropic.maybe_add_thinking(%{model: @haiku}, cfg).thinking.budget_tokens == 5_000
    end

    test "openai maps an unknown effort to medium (not omit)" do
      body =
        OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: Effort.current())

      assert body.reasoning_effort == "medium"
    end

    test "gemini + ollama do not crash on the fallback budget" do
      cfg =
        Google.build_thinking_config(@gemini_thinking, thinking_budget: Effort.thinking_budget())

      assert cfg == %{thinkingConfig: %{thinkingBudget: 5_000}}

      assert Ollama.apply_think(%{}, @ollama_flat, []) == %{}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp session_effort do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp clear_session_effort do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.delete(:osa_settings, {:session, :effort_level})
    end
  end

  defp restore_session_effort(:missing), do: clear_session_effort()

  defp restore_session_effort({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.insert(:osa_settings, {{:session, :effort_level}, value})
    end
  end
end
