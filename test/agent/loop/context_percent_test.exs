defmodule OptimalSystemAgent.Agent.Loop.ContextPercentTest do
  @moduledoc """
  Locks in the context-usage percentage pipeline the status bar renders:

    used_tokens  = provider usage when available, else a char/word estimate
    percent      = used_tokens / effective_window (CC parity)

  The critical regression this guards is the glm/Ollama case: those providers
  return no `usage`, so `last_input_tokens` stays 0. The meter must fall back to
  the estimate and show real occupancy, NOT stick at 0%.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds, as: T

  # Mirror of the `last_input_tokens > 0 ? last_input : estimate` decision used by
  # `Telemetry.emit_context_pressure/1` and `Loop.used_context_tokens/1`.
  defp used_tokens(last_input, messages) do
    if is_integer(last_input) and last_input > 0,
      do: last_input,
      else: Compactor.estimate_tokens(messages)
  end

  test "prefers real provider usage when reported" do
    messages = [%{role: "user", content: "hello there"}]
    # Provider reported 40k input tokens — that wins over the tiny estimate.
    assert used_tokens(40_000, messages) == 40_000
  end

  test "falls back to a char/word estimate when usage is 0 (glm/Ollama)" do
    messages =
      for i <- 1..50 do
        %{role: "user", content: "This is message #{i} with a fair amount of words in it."}
      end

    used = used_tokens(0, messages)

    # The estimate must be a real positive count, never 0 — otherwise the meter
    # would falsely read 0% for the entire session on providers without usage.
    assert used > 0

    # And it must turn into a real, non-zero percentage against the effective
    # window (200k model → 180k effective).
    pct = T.used_percent(used, 200_000)
    assert pct > 0.0
    assert pct <= 100.0
  end

  test "empty conversation reads 0% (no phantom usage)" do
    assert used_tokens(0, []) == 0
    assert T.used_percent(used_tokens(0, []), 200_000) == 0.0
  end

  test "percentage is measured against the effective window, not the raw window" do
    # 90k of a 200k model: 50% of the 180k effective window, not 45% of raw 200k.
    assert T.used_percent(90_000, 200_000) == 50.0
    refute T.used_percent(90_000, 200_000) == 45.0
  end
end
