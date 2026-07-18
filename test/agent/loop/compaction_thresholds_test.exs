defmodule OptimalSystemAgent.Agent.Loop.CompactionThresholdsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds, as: T

  test "200k window uses CC reserve math" do
    assert T.effective_window(200_000) == 180_000
    assert T.compact_at(200_000) == 167_000
    assert T.warn_at(200_000) == 147_000
    assert T.block_at(200_000) == 177_000
  end

  test "128k window: compact fires near 95k, not a fixed 0.75*window" do
    assert T.compact_at(128_000) == 95_000
    assert T.warn_at(128_000) == 75_000
    assert T.block_at(128_000) == 105_000
  end

  test "small window falls back to ratios with sane ordering" do
    cw = 32_000
    assert T.warn_at(cw) < T.compact_at(cw)
    assert T.compact_at(cw) < T.block_at(cw)
    assert T.compact_at(cw) == trunc(cw * 0.75)
  end

  test "warning_state classifies bands" do
    cw = 200_000

    below = T.warning_state(100_000, cw)
    refute below.above_warning
    refute below.above_compact

    warn = T.warning_state(150_000, cw)
    assert warn.above_warning
    refute warn.above_compact

    over = T.warning_state(170_000, cw)
    assert over.above_compact
    refute over.at_blocking_limit

    blocked = T.warning_state(178_000, cw)
    assert blocked.at_blocking_limit
    assert blocked.percent_left == 0
  end
end
