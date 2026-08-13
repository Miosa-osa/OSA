defmodule OptimalSystemAgent.Agent.ModelResolutionTest do
  @moduledoc """
  A session started without an explicit model carried `model: nil`, and nil is
  not an absence — it is a value that silently breaks everything keyed on the
  model.

  Two consequences, both measured on a 40-instance benchmark run:

    * pricing logged `No price for model nil`, so `session_cost_usd` stayed 0
      and `max_budget_usd` could never trip — the run reported a cost of $0.00
      on 59.9M input tokens;
    * `ContextWindow.resolve/1` returned `:unknown`, so the pressure meter read
      `max=0 util=0.0%` and `above_compact` could never become true. Compaction
      never fired at all, on 37 of 40 sessions.

  The second is the dangerous one: it does not fail, it just quietly stops
  protecting a long run.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ContextWindow
  alias OptimalSystemAgent.Providers.Registry

  test "the default model resolves to a real, named model" do
    model = Registry.resolved_default_model()

    assert is_binary(model) and model != "",
           "no default model resolves — a session with no explicit model gets nil"
  end

  test "the resolver survives provider_info's tuple reply" do
    # provider_info/1 replies {:ok, map}. Matching a bare map against it yields
    # nil for EVERY provider while looking correct — the same slip that made
    # `osa.run --format json` report a cost of 0.
    assert {:ok, %{default_model: _}} = Registry.provider_info(Registry.resolved_default_provider())
  end

  test "a resolved model yields a usable context window, not :unknown" do
    # This is the link that disabled compaction. A nil model gives :unknown,
    # which the pressure emitter turns into max=0, which makes above_compact
    # permanently false.
    model = Registry.resolved_default_model()
    resolved = ContextWindow.resolve(%{model: model, provider: nil})

    assert {:ok, cw} = resolved
    assert is_integer(cw) and cw > 0, "context window resolved to #{inspect(resolved)}"
  end

  test "a nil model is exactly what produces the broken state" do
    # Pins the mechanism rather than the symptom, so the reason this fix exists
    # cannot be lost.
    assert ContextWindow.resolve(%{model: nil, provider: nil}) == :unknown
  end
end
