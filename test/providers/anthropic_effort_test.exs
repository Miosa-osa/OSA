defmodule OptimalSystemAgent.Providers.AnthropicEffortTest do
  @moduledoc """
  `output_config.effort` — the only thing that carries reasoning depth on an
  adaptive-thinking Claude model.

  ## The defect this pins

  `thinking: {type: "adaptive"}` is byte-identical at every OSA effort tier.
  Anthropic removed the fixed thinking budget on the Claude 5 family and on
  Opus 4.7/4.8, and steers depth with a SEPARATE top-level
  `output_config.effort` instead. OSA sent that field from nowhere, so the
  entire `Agent.Effort` ladder was a silent no-op on every current Claude
  model: `/effort fast` and `/effort ultra` produced the same request bytes.
  The tier was only ever visible to Haiku 4.5, the one remaining `:budget`
  model, via `budget_tokens`.

  That matters more than any harness change: Anthropic's own Opus 4.6 system
  card measures 10.3 points of movement on effort alone (55.1 at low → 65.4 at
  max) under a FIXED harness, against a 7.2-point harness delta on the same
  task set.

  ## Support is per-model and is NOT uniform

  `xhigh` was introduced with Opus 4.7 — Opus 4.6 and Sonnet 4.6 reject it —
  and Haiku 4.5 has no effort parameter at all, where sending the field is a
  request error rather than a degraded response.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Providers.AnthropicModels

  # :full — the whole ladder, low..max
  @opus5 "claude-opus-5"
  @sonnet5 "claude-sonnet-5"
  @fable5 "claude-fable-5"
  @opus48 "claude-opus-4-8"
  @opus47 "claude-opus-4-7"
  # :no_xhigh — xhigh arrived with Opus 4.7
  @opus46 "claude-opus-4-6"
  @sonnet46 "claude-sonnet-4-6"
  # :none — the field errors here
  @haiku "claude-haiku-4-5"

  setup do
    prev = %{
      effort_level: Application.get_env(:optimal_system_agent, :effort_level),
      session: session_effort()
    }

    on_exit(fn ->
      restore_session_effort(prev.session)

      case prev.effort_level do
        nil -> Application.delete_env(:optimal_system_agent, :effort_level)
        v -> Application.put_env(:optimal_system_agent, :effort_level, v)
      end
    end)

    :ok
  end

  # ── The ladder maps one-to-one, with :ultra landing on max ─────────────────

  describe "the OSA ladder maps onto Anthropic's" do
    for {tier, wire} <- [
          {:fast, "low"},
          {:medium, "medium"},
          {:high, "high"},
          {:xhigh, "xhigh"},
          {:ultra, "max"}
        ] do
      test "#{tier} → effort=#{wire} on a full-ladder model" do
        assert AnthropicModels.effort_value(@opus5, unquote(tier)) == unquote(wire)
      end
    end

    test "legacy OSA names route through Effort.normalize/1" do
      # OSA renamed :low → :fast and :max → :xhigh. The rung that means "spend
      # everything" is :ultra, which is what lands on Anthropic's `max`.
      assert AnthropicModels.effort_value(@opus5, :low) == "low"
      assert AnthropicModels.effort_value(@opus5, :max) == "xhigh"
      assert AnthropicModels.effort_value(@opus5, "ultra") == "max"
      # "off" normalizes to :fast — thinking is disabled separately, via
      # fast_mode, not by omitting effort.
      assert AnthropicModels.effort_value(@opus5, "off") == "low"
    end

    test "string and atom forms agree" do
      for tier <- ~w(fast medium high xhigh ultra) do
        assert AnthropicModels.effort_value(@opus5, tier) ==
                 AnthropicModels.effort_value(@opus5, String.to_atom(tier))
      end
    end
  end

  # ── Per-model support ─────────────────────────────────────────────────────

  describe "per-model effort support" do
    test "the current Claude generation takes the whole ladder" do
      for model <- [@opus5, @sonnet5, @fable5, @opus48, @opus47] do
        assert AnthropicModels.effort_levels(model) == ~w(low medium high xhigh max),
               "#{model} should accept every effort level"
      end
    end

    test "4.6 rejects xhigh, so an xhigh request clamps DOWN to high" do
      # Clamping UP to `max` would silently make a run more expensive than the
      # operator asked for. Down is the safe direction.
      for model <- [@opus46, @sonnet46] do
        refute "xhigh" in AnthropicModels.effort_levels(model)
        assert AnthropicModels.effort_value(model, :xhigh) == "high"
        # ...but `ultra` still reaches `max`, which 4.6 does accept.
        assert AnthropicModels.effort_value(model, :ultra) == "max"
        assert AnthropicModels.effort_value(model, :medium) == "medium"
      end
    end

    test "Haiku 4.5 has no effort parameter — the field is omitted at every tier" do
      assert AnthropicModels.effort_levels(@haiku) == []

      for tier <- [:fast, :medium, :high, :xhigh, :ultra] do
        assert AnthropicModels.effort_value(@haiku, tier) == nil
        assert Anthropic.build_output_config(@haiku, reasoning_effort: tier) == nil
      end
    end

    test "an unknown model id is assumed current-generation" do
      # Matches thinking_mode/1's default. The failure mode of guessing wrong
      # is a 400 on one request, not a silently inert ladder forever.
      assert AnthropicModels.effort_value("claude-opus-6-unreleased", :ultra) == "max"
    end
  end

  # ── An unpinnable level omits the field rather than guessing ──────────────

  describe "unrecognised effort omits the field" do
    test "a corrupt persisted level does not fabricate a tier" do
      # Anthropic's own default is `high`. Sending a guessed value would make
      # the run look pinned when it is not — and an unpinned run is exactly
      # what makes a benchmark number unquotable, so it must stay visible.
      assert AnthropicModels.effort_value(@opus5, "banana-nonsense") == nil
      assert AnthropicModels.effort_value(@opus5, nil) == nil
      assert Anthropic.build_output_config(@opus5, reasoning_effort: "banana-nonsense") == nil
    end
  end

  # ── Resolution order + the request body ───────────────────────────────────

  describe "build_output_config/2 resolution order" do
    test "explicit :reasoning_effort wins over the live setting" do
      Effort.set(:fast)
      assert Anthropic.build_output_config(@opus5, reasoning_effort: :ultra) == %{effort: "max"}
    end

    test ":effort is accepted as an alias, matching the other transports" do
      Effort.set(:fast)
      assert Anthropic.build_output_config(@opus5, effort: :high) == %{effort: "high"}
    end

    test "with no opt at all it falls back to the LIVE setting, not a constant" do
      # This is the whole point: nothing on the normal turn path passes
      # :reasoning_effort, so a constant here is indistinguishable from
      # sending nothing.
      Effort.set(:ultra)
      assert Anthropic.build_output_config(@opus5, []) == %{effort: "max"}

      Effort.set(:fast)
      assert Anthropic.build_output_config(@opus5, []) == %{effort: "low"}
    end
  end

  describe "the field reaches the request body" do
    test "every tier produces a DIFFERENT body — the regression this pins" do
      bodies =
        for tier <- [:fast, :medium, :high, :xhigh, :ultra] do
          Effort.set(tier)

          %{model: @opus5}
          |> Anthropic.maybe_add_thinking(%{type: "adaptive"})
          |> Anthropic.maybe_add_output_config(@opus5, [])
        end

      # Before this existed all five were byte-identical.
      assert length(Enum.uniq(bodies)) == 5,
             "effort is inert again — every tier produced the same request body"

      # ...and the thinking block is STILL the reason: it is identical in all
      # five. Depth rides entirely on output_config.
      assert bodies |> Enum.map(& &1.thinking) |> Enum.uniq() == [
               %{type: "adaptive", display: "summarized"}
             ]

      assert Enum.map(bodies, & &1.output_config) == [
               %{effort: "low"},
               %{effort: "medium"},
               %{effort: "high"},
               %{effort: "xhigh"},
               %{effort: "max"}
             ]
    end

    test "a model with no effort parameter gets no output_config key at all" do
      Effort.set(:ultra)
      body = Anthropic.maybe_add_output_config(%{model: @haiku}, @haiku, [])
      refute Map.has_key?(body, :output_config)
    end

    test "the rest of the body is untouched" do
      Effort.set(:high)
      base = %{model: @opus5, max_tokens: 4096, messages: []}
      body = Anthropic.maybe_add_output_config(base, @opus5, [])

      assert Map.delete(body, :output_config) == base
    end
  end

  # ── Never the thing that kills a turn ─────────────────────────────────────

  test "an unresolvable setting degrades to omission, not a crash" do
    clear_session_effort()
    Application.put_env(:optimal_system_agent, :effort_level, {:not, :a, :level})

    assert Anthropic.build_output_config(@opus5, []) == nil
    assert Anthropic.maybe_add_output_config(%{model: @opus5}, @opus5, []) == %{model: @opus5}
  end

  test "a nil model does not raise" do
    Effort.set(:high)
    assert %{effort: "high"} = Anthropic.build_output_config(nil, [])
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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
