defmodule OptimalSystemAgent.Agent.Loop.ModelSwapTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.ModelSwap

  test "quota hop of equal window keeps the transcript" do
    assert ModelSwap.plan(200_000, 200_000, 180_000, 40) == :keep
  end

  test "larger window keeps the transcript" do
    assert ModelSwap.plan(200_000, 1_000_000, 180_000, 40) == :keep
  end

  test "empty transcript never compacts even if occupancy looks high" do
    assert ModelSwap.plan(1_000_000, 32_000, 400_000, 0) == :keep
  end

  test "zero occupancy never compacts" do
    assert ModelSwap.plan(1_000_000, 32_000, 0, 12) == :keep
  end

  test "shrinking below compact_at of the new window keeps the transcript" do
    compact_at = CompactionThresholds.compact_at(200_000)
    occupancy = max(compact_at - 5_000, 1)
    assert ModelSwap.plan(1_000_000, 200_000, occupancy, 20) == :keep
  end

  test "1M @ 400k onto 200k compacts immediately" do
    compact_at = CompactionThresholds.compact_at(200_000)
    assert 400_000 >= compact_at
    assert ModelSwap.plan(1_000_000, 200_000, 400_000, 80) == :compact
  end

  test "unknown previous window does not compact — quota hops must keep history" do
    assert ModelSwap.plan(nil, 200_000, 400_000, 80) == :keep
    assert ModelSwap.plan(0, 32_000, 400_000, 80) == :keep
  end

  test "apply resolves the old window from model/provider when the struct field is nil" do
    alias OptimalSystemAgent.Agent.Loop

    state = %Loop{
      session_id: "swap-nil-window-#{System.unique_integer([:positive])}",
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      effective_context_window: nil,
      last_input_tokens: 400_000,
      messages: [%{role: "user", content: "hello there, keep this"}]
    }

    window =
      OptimalSystemAgent.Providers.Registry.effective_context_window(
        "claude-sonnet-4-6",
        :anthropic
      )

    {_new_state, info} = ModelSwap.apply(state, :anthropic, "claude-sonnet-4-6", window)

    assert info.compacted == false
    assert info.old_context_window == window
    assert info.context_window == window
  end
end
