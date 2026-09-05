defmodule OptimalSystemAgent.Providers.FastServiceTierSettingsTest do
  @moduledoc """
  The two readers of `openai_fast_service_tier` have to agree.

  `fast_service_tier?/0` resolves the full settings cascade, while
  `fast_service_tier?/1` (the arity the turn path uses) read only the in-memory
  session rows. So `openai_fast_service_tier` set in `~/.osa/settings.json` or
  in an `OSA_SETTINGS` flag file was on for one reader and off for the other,
  which is the worst version of a boolean: a headless run configured for fast
  processing quietly did not get it.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Settings

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-fast-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    session = "fast-cascade-#{System.unique_integer([:positive])}"
    other = "fast-other-#{System.unique_integer([:positive])}"
    prev_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)

    on_exit(fn ->
      if prev_flag,
        do: Application.put_env(:optimal_system_agent, :settings_flag_path, prev_flag),
        else: Application.delete_env(:optimal_system_agent, :settings_flag_path)

      Settings.clear_session(session)
      Settings.clear_session(other)
      # The daemon-wide row too: left behind it would turn fast processing on
      # for every session in every test that runs after this one.
      Settings.delete_session_for(nil, :openai_fast_service_tier)
      Settings.reset_cache()
      File.rm_rf(dir)
    end)

    # A machine-authored layer (the `--settings` / OSA_SETTINGS path), which is
    # the supported way for a headless run to impose policy.
    flag = Path.join(dir, "settings.json")
    File.write!(flag, Jason.encode!(%{"openai_fast_service_tier" => true}))

    %{dir: dir, flag: flag, session: session, other: other}
  end

  defp use_flag_file(flag) do
    Application.put_env(:optimal_system_agent, :settings_flag_path, flag)
    Settings.reset_cache()
  end

  test "a file-layer setting reaches the per-session reader too", ctx do
    use_flag_file(ctx.flag)

    assert LLMClient.fast_service_tier?()
    assert LLMClient.fast_service_tier?(ctx.session)

    # And therefore reaches the turn path, which is the only reader that
    # decides whether a request actually carries a tier.
    assert LLMClient.service_tier_for(%{provider: :anthropic, session_id: ctx.session}) == "auto"
  end

  test "a session row still shadows the file layer", ctx do
    use_flag_file(ctx.flag)
    Settings.set_session_for(ctx.session, :openai_fast_service_tier, false)

    refute LLMClient.fast_service_tier?(ctx.session)
    assert LLMClient.fast_service_tier?(ctx.other)
  end

  test "with no file layer the session rows still decide", ctx do
    Application.delete_env(:optimal_system_agent, :settings_flag_path)
    Settings.reset_cache()

    refute LLMClient.fast_service_tier?(ctx.session)
    assert LLMClient.toggle_fast_service_tier(ctx.session)
    assert LLMClient.fast_service_tier?(ctx.session)
    refute LLMClient.fast_service_tier?(ctx.other)
  end

  test "a toggle with no session id scopes to the caller's own session", ctx do
    Application.delete_env(:optimal_system_agent, :settings_flag_path)
    Settings.reset_cache()

    # What the turn pipeline publishes for the process it runs the turn on.
    Process.put(:osa_session_id, ctx.session)

    assert LLMClient.toggle_fast_service_tier(nil)
    assert LLMClient.fast_service_tier?(ctx.session)

    # The point of the guard: a missing id must not write the daemon-wide row
    # that every OTHER session resolves underneath its own.
    refute LLMClient.fast_service_tier?(ctx.other)
  after
    Process.delete(:osa_session_id)
  end
end
