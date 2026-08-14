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

  test ":lite is still nowhere near the 4-6k it was documented as" do
    lite = Soul.static_token_count(:lite)

    # Was `> 15_000` when :lite measured 24,375. The prompt-prefix cut brought
    # it to ~12.2k, so the floor moved — but the POINT of the assertion did
    # not: :lite is a middleweight prompt, not the ~4-6k one its name and its
    # old comments promised. Anything under 8k here means it finally became
    # that small prompt, and Soul's + Agent.Context's docs must say so.
    assert lite > 8_000,
           "if :lite really did drop to #{lite} tokens, the comments in Soul and " <>
             "Agent.Context that now say ~12k are the thing that is wrong — update them"

    assert lite < 20_000,
           "lite grew back to #{lite} tokens — the prefix cut is regressing"
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

  test "the static prefix stays inside the budget the prefix cut bought" do
    # The cut that produced these numbers took the assembled prefix
    # (`:native_tools` base + the native tool-schema array) from ~21.6k to
    # ~14.4k tokens on this machine. This is the regression fence: prose grows
    # back one paragraph at a time, and 90% of OSA's input volume is this
    # prefix multiplied by turn count.
    native = Soul.static_token_count(:native_tools)

    # NOTE: this figure includes whatever the developer keeps in `~/.osa/rules/`,
    # which is interpolated as `{{RULES}}`. The bound carries ~2k of headroom
    # over the 8.1k measured with one ~1.1k user rule loaded. A very large
    # personal rules directory can trip it legitimately.
    assert native < 10_000,
           "the :native_tools base is #{native} tokens — it was cut to ~8.1k. " <>
             "Either something re-inflated the static prompt (check SYSTEM_LEAN.md " <>
             "and the tool `prompt/1` callbacks) or ~/.osa/rules/ is unusually large."
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
