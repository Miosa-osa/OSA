defmodule OptimalSystemAgent.Soul.StaticBaseSizeTest do
  @moduledoc """
  Pins the measured size of each static-base variant.

  `Agent.Context` documented `:lite` as keeping the static base "~4-6k instead
  of ~24k". It was 24,375 tokens — about five times the claim, and essentially
  the size it was said to replace. Every local-provider session budgets against
  that number, so a documented figure this far off is not a comment problem: it
  is how a 32k window ends up with under 4k for the conversation.

  These assertions are ranges, not equalities — SYSTEM.md and the tool list
  change legitimately. What they enforce is that the ORDERING and the ORDER OF
  MAGNITUDE stay true to what the surrounding comments say.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Soul

  test ":lite is nowhere near the 4-6k it was documented as" do
    lite = Soul.static_token_count(:lite)

    assert lite > 15_000,
           "if :lite really did drop to #{lite} tokens, the comments in Soul and " <>
             "Agent.Context that now say ~24k are the thing that is wrong — update them"

    assert lite < 32_000
  end

  test ":lite is smaller than :full but only by the tool section" do
    full = Soul.static_token_count(:full)
    lite = Soul.static_token_count(:lite)

    assert lite < full
    # The saving is the trimmed tool docs, not a different prompt.
    assert full - lite < 12_000,
           "lite saves #{full - lite} tokens — if it now saves substantially more, " <>
             "it has become a genuinely small prompt and the docs should say so"
  end

  test ":native_tools, not :lite, is the smallest variant" do
    # Documented in `Soul.static_base/1`: worth knowing before anyone treats
    # "lite" as the cheap option. Context deliberately still prefers :lite for
    # local providers, because :native_tools assumes the transport carries the
    # tool schemas.
    assert Soul.static_token_count(:native_tools) < Soul.static_token_count(:lite)
    assert Soul.static_token_count(:native_tools) < Soul.static_token_count(:full)
  end

  test "every variant reports a non-zero count and a matching body" do
    for variant <- [:full, :lite, :native_tools] do
      assert Soul.static_token_count(variant) > 0
      assert byte_size(Soul.static_base(variant)) > 0
    end
  end
end
