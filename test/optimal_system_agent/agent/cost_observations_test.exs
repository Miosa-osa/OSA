defmodule OptimalSystemAgent.Agent.CostObservationsTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Agent.CostObservations

  setup do
    CostObservations.reset()
    on_exit(&CostObservations.reset/0)
    :ok
  end

  test "nil for an unseen model" do
    assert CostObservations.avg_cost(:openai, "gpt-5") == nil
  end

  test "first sample is the value; then EMA moves toward new samples" do
    CostObservations.record(:openai, "gpt-5", 1.0)
    assert CostObservations.avg_cost(:openai, "gpt-5") == 1.0
    CostObservations.record(:openai, "gpt-5", 2.0)
    v = CostObservations.avg_cost(:openai, "gpt-5")
    # EMA with alpha 0.3: 1.0 + 0.3*(2.0-1.0) = 1.3
    assert_in_delta v, 1.3, 1.0e-9
  end

  test "ignores zero / nil / missing keys (no basis to learn)" do
    CostObservations.record(:openai, "gpt-5", 0.0)
    CostObservations.record(:openai, "gpt-5", nil)
    CostObservations.record(nil, "gpt-5", 1.0)
    CostObservations.record(:openai, nil, 1.0)
    assert CostObservations.avg_cost(:openai, "gpt-5") == nil
  end

  test "telemetry handler folds provider_cost_usd (falls back to estimate)" do
    CostObservations.handle_telemetry(
      [:osa, :accounting, :provider_cost],
      %{provider_cost_usd: 0.5, rate_card_estimate_usd: 0.9},
      %{provider: :openai, model: "gpt-5"},
      nil
    )

    assert CostObservations.avg_cost(:openai, "gpt-5") == 0.5

    CostObservations.handle_telemetry(
      [:osa, :accounting, :provider_cost],
      %{provider_cost_usd: 0, rate_card_estimate_usd: 0.2},
      %{provider: :anthropic, model: "opus"},
      nil
    )

    assert CostObservations.avg_cost(:anthropic, "opus") == 0.2
  end
end
