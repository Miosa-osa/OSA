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

  test "used_percent measures against the effective window (CC parity)" do
    cw = 200_000
    # Effective window is 180k, so half-full-of-effective reads 50%.
    assert T.used_percent(90_000, cw) == 50.0
    # Empty session reads 0%.
    assert T.used_percent(0, cw) == 0.0
    # At the auto-compact threshold the meter should read ~93% (compact_at is one
    # 13k buffer below the 180k effective window), NOT ~84% (against raw 200k).
    pct_at_compact = T.used_percent(T.compact_at(cw), cw)
    assert_in_delta pct_at_compact, 92.8, 0.2
    assert pct_at_compact > 90.0
  end

  test "used_percent clamps over-full and guards bad input" do
    # A transient over-count never renders above 100%.
    assert T.used_percent(500_000, 200_000) == 100.0
    # Zero / non-positive window degrades to 0.0 rather than dividing by zero.
    assert T.used_percent(1_000, 0) == 0.0
    assert T.used_percent(-5, 200_000) == 0.0
  end

  test "used_percent on a tiny local window falls back to the raw window" do
    # effective_window(8_000) is negative, so the denominator falls back to the
    # raw window and stays aligned with the 75% ratio-based compaction fallback.
    cw = 8_000
    assert T.used_percent(4_000, cw) == 50.0
    assert T.used_percent(T.compact_at(cw), cw) == 75.0
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

  # ── the bands must be ordered at EVERY window, not just the big ones ───────
  #
  # For cw in (66_000, 70_667] the reserve path won for compact_at while warn_at
  # fell through to its 0.60*cw fallback, and 0.60*cw > cw - 33_000 across that
  # whole range. At cw = 70_000 that put warn_at (42_000) ABOVE compact_at
  # (37_000), which silently made `should_microcompact?/2`'s guard
  # (tokens >= warn_at and tokens < compact_at) unsatisfiable and clamped the
  # memory flush to a band one token wide. Both failures were invisible.

  test "warn_at stays below compact_at at the window that used to invert it" do
    assert T.warn_at(70_000) < T.compact_at(70_000)
  end

  test "the bands are strictly ordered across every plausible window" do
    windows =
      [1_000, 4_096, 8_192, 16_384, 32_768, 65_536, 128_000, 200_000, 1_000_000] ++
        Enum.to_list(60_000..80_000//500)

    for cw <- windows do
      warn = T.warn_at(cw)
      compact = T.compact_at(cw)
      block = T.block_at(cw)

      assert warn < compact, "cw=#{cw}: warn_at #{warn} must be below compact_at #{compact}"
      assert compact < block, "cw=#{cw}: compact_at #{compact} must be below block_at #{block}"
      assert warn > 0, "cw=#{cw}: warn_at must be positive"
    end
  end

  test "the microcompaction band is wide enough to be reachable" do
    # A one-token band is an unreachable band in practice: nothing exists to
    # write durable notes in, and the cheap non-LLM path never runs.
    for cw <- Enum.to_list(60_000..80_000//500) ++ [1_000, 8_192, 128_000, 200_000] do
      compact = T.compact_at(cw)
      width = compact - T.warn_at(cw)
      # The full warning buffer where the window can afford it, and a quarter of
      # compact_at where it cannot — never one token.
      floor = min(20_000, div(compact, 4))

      assert width >= floor,
             "cw=#{cw}: band of #{width} tokens is narrower than the #{floor} floor"
    end
  end
end
