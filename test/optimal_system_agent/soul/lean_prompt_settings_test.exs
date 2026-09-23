defmodule OptimalSystemAgent.Soul.LeanPromptSettingsTest do
  @moduledoc """
  `Soul.lean_prompt?/0` and `Soul.lean_system_prompt?/0` used to read ONLY
  `Application.get_env/3`, which meant the sole way to change either flag on
  an installed release was to hand-edit the compiled `sys.config` — silently
  reverted on every OSA update. They now resolve through the same settings
  cascade `MCP.Discovery.import_enabled?/0` already uses for
  `mcp_import_foreign` (`~/.osa/settings.json` first, app env second, then
  the flag's own default), so `/lean-prompt on|off` survives an update.

  This file pins:

    1. the resolution order (settings.json beats app env, beats default) for
       BOTH flags independently,
    2. that an absent key still falls through to app env, and
    3. that the `:persistent_term`-cached static base — process-wide, NOT
       per-session — actually picks up a settings.json change on its own
       next read, with no explicit `Soul.invalidate_static_base()` call.
       That last property is the whole point of folding the two flags into
       `tools_fingerprint/1`: without it, a `/lean-prompt` toggle would sit
       inert until something else (a tool registering, `Soul.reload/0`)
       happened to invalidate the cache.

  `lean_prompt_test.exs` continues to own the "what the lean template
  actually drops" content assertions; this file is scoped to resolution +
  caching only.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Soul

  setup do
    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_lean_prompt = Application.get_env(:optimal_system_agent, :lean_prompt)
    prev_lean_system_prompt = Application.get_env(:optimal_system_agent, :lean_system_prompt)

    home =
      Path.join(System.tmp_dir!(), "osa-lean-settings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:optimal_system_agent, :config_dir, home)
    Settings.reset_cache()

    on_exit(fn ->
      File.rm_rf(home)
      restore(:config_dir, prev_config_dir)
      restore(:lean_prompt, prev_lean_prompt)
      restore(:lean_system_prompt, prev_lean_system_prompt)
      Settings.reset_cache()
      Soul.invalidate_static_base()
    end)

    {:ok, home: home}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp write_settings(home, map) do
    File.write!(Path.join(home, "settings.json"), Jason.encode!(map))
    Settings.reset_cache()
  end

  describe "lean_system_prompt?/0 resolution order" do
    test "settings.json true overrides an app-env false", %{home: home} do
      Application.put_env(:optimal_system_agent, :lean_system_prompt, false)
      write_settings(home, %{"lean_system_prompt" => true})

      assert Soul.lean_system_prompt?()
    end

    test "settings.json false overrides an app-env true (explicit decision wins)", %{home: home} do
      Application.put_env(:optimal_system_agent, :lean_system_prompt, true)
      write_settings(home, %{"lean_system_prompt" => false})

      refute Soul.lean_system_prompt?()
    end

    test "an absent key falls back to app env", %{home: home} do
      write_settings(home, %{})

      Application.put_env(:optimal_system_agent, :lean_system_prompt, true)
      assert Soul.lean_system_prompt?()

      Application.put_env(:optimal_system_agent, :lean_system_prompt, false)
      refute Soul.lean_system_prompt?()
    end

    test "default is false (full SYSTEM.md) when neither is set", %{home: home} do
      write_settings(home, %{})
      Application.delete_env(:optimal_system_agent, :lean_system_prompt)

      refute Soul.lean_system_prompt?()
    end
  end

  describe "lean_prompt?/0 resolution order" do
    test "settings.json overrides app env", %{home: home} do
      Application.put_env(:optimal_system_agent, :lean_prompt, true)
      write_settings(home, %{"lean_prompt" => false})

      refute Soul.lean_prompt?()
    end

    test "an absent key falls back to app env", %{home: home} do
      write_settings(home, %{})

      Application.put_env(:optimal_system_agent, :lean_prompt, false)
      refute Soul.lean_prompt?()
    end

    test "default is true (skip unfilled bundled rules) when neither is set", %{home: home} do
      write_settings(home, %{})
      Application.delete_env(:optimal_system_agent, :lean_prompt)

      assert Soul.lean_prompt?()
    end
  end

  describe "cache invalidation" do
    test "a settings.json toggle rebuilds the cached static base with no explicit invalidate",
         %{home: home} do
      Application.put_env(:optimal_system_agent, :lean_prompt, false)
      write_settings(home, %{"lean_system_prompt" => false})
      Soul.invalidate_static_base()
      long = await_stable(fn -> Soul.static_base(:native_tools) end)

      write_settings(home, %{"lean_system_prompt" => true})
      # No Soul.invalidate_static_base() here — this is the property under
      # test. The persistent_term cache is process-wide; if the fingerprint
      # did not fold in the flag, this read would keep returning `long`.
      lean = Soul.static_base(:native_tools)

      assert byte_size(lean) < byte_size(long),
             "static_base/1 (#{byte_size(lean)} B) did not shrink after the settings.json " <>
               "flag flipped to lean (long was #{byte_size(long)} B) — the persistent_term " <>
               "cache key does not track lean_system_prompt?/0"
    end

    test "flipping back to full restores the long template, again with no explicit invalidate",
         %{home: home} do
      Application.put_env(:optimal_system_agent, :lean_prompt, false)
      write_settings(home, %{"lean_system_prompt" => true})
      Soul.invalidate_static_base()
      lean = await_stable(fn -> Soul.static_base(:native_tools) end)

      write_settings(home, %{"lean_system_prompt" => false})
      long = Soul.static_base(:native_tools)

      assert byte_size(long) > byte_size(lean)
    end
  end

  # Same purpose as `StaticBaseFingerprintTest.await_stable_build/2`: the live
  # tool registry and every bundled rule file are inputs `build_base/1` reads
  # fresh, and either changing mid-suite would make this test's baseline
  # unstable for a reason that has nothing to do with the flag. Wait for two
  # consecutive identical builds before either real assertion starts.
  defp await_stable(build, prev \\ nil, tries \\ 80)
  defp await_stable(build, _prev, 0), do: build.()

  defp await_stable(build, prev, tries) do
    current = build.()

    if current == prev do
      current
    else
      Process.sleep(25)
      await_stable(build, current, tries - 1)
    end
  end
end
