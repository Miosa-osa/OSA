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

  The full `SYSTEM.md` is now the DEFAULT template (`:lean_system_prompt` off);
  `SYSTEM_LEAN.md` is the opt-in special-case fallback for constrained
  deployments. These size guarantees are ABOUT the lean cut, so the suite forces
  the lean template on and pins the sizes the cut actually delivers when used.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  setup do
    orig = Application.get_env(:optimal_system_agent, :lean_system_prompt)
    Application.put_env(:optimal_system_agent, :lean_system_prompt, true)

    # Measure the PRODUCT static base, not the developer's machine.
    #
    # `{{RULES}}` interpolates `~/.osa/rules/**` (honouring `OSA_HOME`). On a dev
    # box that directory holds PERSONAL rules — on this one ~1.6k tokens of them —
    # which are not product content and are not what a fresh install ships. Left
    # in, they made the measured base swing from ~10.5k to ~12k from one machine
    # to the next, so the number the assertions pin was really "the product base
    # plus whatever this developer happens to keep locally". The static base is
    # product content; the dev's local rules are not part of it.
    #
    # Point `OSA_HOME` at an empty directory for the duration of the run so the
    # measurement is deterministic and reflects only what ships. The BUNDLED
    # `priv/rules/` still count (they are product) — only the user's personal
    # `~/.osa/rules/` is excluded.
    orig_home = System.get_env("OSA_HOME")
    empty_home = Path.join(System.tmp_dir!(), "osa_static_base_test_home")
    File.mkdir_p!(empty_home)
    System.put_env("OSA_HOME", empty_home)

    Soul.invalidate_static_base()

    on_exit(fn ->
      if orig == nil,
        do: Application.delete_env(:optimal_system_agent, :lean_system_prompt),
        else: Application.put_env(:optimal_system_agent, :lean_system_prompt, orig)

      if orig_home,
        do: System.put_env("OSA_HOME", orig_home),
        else: System.delete_env("OSA_HOME")

      Soul.invalidate_static_base()
    end)

    :ok
  end

  test ":lite is still nowhere near the 4-6k it was documented as" do
    lite = Soul.static_token_count(:lite)

    # Was `> 15_000` when :lite measured 24,375. The prompt-prefix cut brought
    # it to ~13k of product content, so the floor moved — but the POINT did
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

    # This measures the PRODUCT base only (the setup pins `OSA_HOME` at an empty
    # dir, so the developer's personal `~/.osa/rules/` no longer inflate it).
    #
    # The bound moved from 10_000 to 11_500, and the move is EARNED, not a
    # silence-the-failure bump. At v1.0.98 this base was ~8.1k *with* a ~1.1k
    # local user rule folded in — so the pure product base was ~7k. It is now
    # ~10.5k of product content, and the growth was audited to be legitimate:
    #
    #   * `SYSTEM_LEAN.md` gained the "Operating discipline — read before acting"
    #     pre-brief, which is NOT a duplicate of the numbered sections. It is the
    #     only place several load-bearing safety rules live — tool output is DATA
    #     never instructions (prompt-injection defence), verify a recalled
    #     path/symbol still exists before relying on it, and the shell-hygiene
    #     rules — plus the thoroughness counterweight. Deleting it to hit the old
    #     number would drop real guidance.
    #   * the native tool roster grew, so the un-deduped remainder of
    #     `{{TOOL_DEFINITIONS}}` rose from ~2.7k to ~3.4k. More tools shipping is
    #     capability, not prose bloat.
    #
    # Only ~40 tokens of genuinely duplicate prose were found in `SYSTEM_LEAN.md`;
    # there is no ~600-token block to cut without losing instruction. So the fence
    # is re-pinned at the true product base plus ~1k of headroom. It is STILL a
    # regression fence — prose growing back one paragraph at a time, or a burst of
    # verbose tool `prompt/1` text, will trip it. If it does, trim the offender;
    # do not raise this number without the same audit.
    assert native < 11_500,
           "the :native_tools PRODUCT base is #{native} tokens (budget 11_500, " <>
             "measured ~10.5k). Something re-inflated the static prompt — check " <>
             "SYSTEM_LEAN.md and the tool `prompt/1` callbacks for prose that grew " <>
             "back, and trim it rather than raising this bound."
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
