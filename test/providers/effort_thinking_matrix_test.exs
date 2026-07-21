defmodule OptimalSystemAgent.Providers.EffortThinkingMatrixTest do
  @moduledoc """
  W4 — the effort × provider thinking matrix.

  Verifies that every effort tier (fast / medium / high / xhigh / ultra, plus
  the `off` wire value) maps to the correct thinking parameter on each provider,
  and that a corrupt / unknown persisted effort never crashes any provider path
  (it falls back to `:medium` via `Effort.get/1`).

  Expected matrix (tier → provider param):

      tier    anthropic-opus        anthropic-nonopus   openai (o-series)   gemini-2.5      ollama
      ----    ------------------    -----------------   -----------------   ------------    ------
      fast    (none — fast_mode)    (none — fast_mode)  reasoning=low       (none, budget0) no-op
      medium  adaptive              enabled/5000        reasoning=medium    budget 5000     no-op
      high    adaptive              enabled/10000       reasoning=high      budget 10000    no-op
      xhigh   adaptive              enabled/32000       reasoning=high      budget 32000    no-op
      ultra   enabled/64000         enabled/64000       reasoning=high      budget 64000    no-op
      off     (none)                (none)              (omit)              (none, budget0) no-op
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Providers.{Anthropic, Google, Ollama, OpenAICompat}

  @opus "claude-opus-4-8"
  @sonnet "claude-sonnet-4-6"
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

    test "opus at ultra → enabled with the 64k max budget" do
      Effort.set(:ultra)
      cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @opus})
      assert cfg == %{type: "enabled", budget_tokens: 64_000}

      body = Anthropic.maybe_add_thinking(%{model: @opus}, cfg)
      assert body.thinking == %{type: "enabled", budget_tokens: 64_000}
    end

    test "opus at fast → no thinking block" do
      Effort.set(:fast)
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @opus}) == nil
    end
  end

  describe "anthropic — non-opus (enabled + effort budget at every non-fast tier)" do
    for {tier, budget} <- [{:medium, 5_000}, {:high, 10_000}, {:xhigh, 32_000}, {:ultra, 64_000}] do
      test "sonnet at #{tier} → enabled with budget #{budget}" do
        Effort.set(unquote(tier))
        cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet})
        assert cfg == %{type: "enabled", budget_tokens: unquote(budget)}

        body = Anthropic.maybe_add_thinking(%{model: @sonnet}, cfg)
        assert body.thinking == %{type: "enabled", budget_tokens: unquote(budget)}
      end
    end

    test "sonnet at fast → no thinking block" do
      Effort.set(:fast)
      assert LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet}) == nil
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

    test "no reasoning_effort opt on an o-series model still defaults to medium" do
      body = OpenAICompat.build_stream_body(@openai_model, [], [])
      assert body.reasoning_effort == "medium"
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

  # ── Ollama (no thinking wiring → clean no-op, never crash) ───────────────────

  describe "ollama — clean no-op regardless of effort tier" do
    for tier <- [:fast, :medium, :high, :xhigh, :ultra] do
      test "effort #{tier} leaves a non-thinking-model body untouched (no crash)" do
        Effort.set(unquote(tier))
        base = %{model: @ollama_flat, messages: []}
        assert Ollama.apply_think(base, @ollama_flat, []) == base
      end
    end

    test "known thinking model defaults think:false (extended reasoning disabled)" do
      Application.delete_env(:optimal_system_agent, :ollama_think)
      body = Ollama.apply_think(%{}, "kimi-k2", [])
      assert body["think"] == false
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

      cfg = LLMClient.thinking_config(%{provider: :anthropic, model: @sonnet})
      assert cfg == %{type: "enabled", budget_tokens: 5_000}
      assert Anthropic.maybe_add_thinking(%{model: @sonnet}, cfg).thinking.budget_tokens == 5_000
    end

    test "openai maps an unknown effort to medium (not omit)" do
      body =
        OpenAICompat.build_stream_body(@openai_model, [], reasoning_effort: Effort.current())

      assert body.reasoning_effort == "medium"
    end

    test "gemini + ollama do not crash on the fallback budget" do
      cfg = Google.build_thinking_config(@gemini_thinking, thinking_budget: Effort.thinking_budget())
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
