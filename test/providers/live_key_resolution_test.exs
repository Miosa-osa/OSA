defmodule OptimalSystemAgent.Providers.LiveKeyResolutionTest do
  @moduledoc """
  Regression coverage for the "keys and the default provider are read from
  BOOT-TIME Application config and never re-read live" root cause (F1/P2/P3):

    * a lone cloud key added AFTER boot (e.g. by the standalone CLI setup
      wizard writing ~/.osa/.env, or a shell `export` in a live session)
      must be visible to `provider_configured?/1` and usable as the resolved
      default provider without a daemon restart
    * `OpenAICompatProvider`'s api-key resolution must fall back to a live
      `System.get_env` read, not only the one-shot `Application.get_env`
      snapshot taken at boot

  Runs `async: false` and mutates real process env / Application env for the
  duration of each test, restoring both afterward — these are process-global,
  so they cannot safely interleave with other async provider tests.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.OpenAICompatProvider, as: Compat
  alias OptimalSystemAgent.Providers.Registry

  # Local/keyless providers are excluded from the registry's own live-key
  # scan (see Registry.default_provider/0's @keyless_providers) — mirror that
  # here so the "exactly one candidate configured" setup is accurate.
  @keyless [:ollama, :ollama_cloud, :lmstudio, :llamacpp, :mock]

  @candidate_providers Registry.list_providers() -- @keyless

  defp env_var(provider),
    do: provider |> Atom.to_string() |> String.upcase() |> Kernel.<>("_API_KEY")

  # Wipes every candidate provider's API key from both live System env AND
  # the Application-config snapshot (which may have been populated at boot
  # from the operator's real shell env), so "exactly one key present" is
  # deterministic regardless of the host running the suite. Restores both on
  # exit.
  defp isolate_provider_env(test_pid) do
    snapshot =
      for provider <- @candidate_providers do
        var = env_var(provider)

        {provider, System.get_env(var),
         Application.get_env(:optimal_system_agent, :"#{provider}_api_key")}
      end

    default_provider_snapshot =
      {System.get_env("OSA_DEFAULT_PROVIDER"),
       Application.get_env(:optimal_system_agent, :default_provider)}

    for provider <- @candidate_providers do
      System.delete_env(env_var(provider))
      Application.delete_env(:optimal_system_agent, :"#{provider}_api_key")
    end

    System.delete_env("OSA_DEFAULT_PROVIDER")

    ExUnit.Callbacks.on_exit(test_pid, fn ->
      for {provider, sys_val, app_val} <- snapshot do
        if sys_val,
          do: System.put_env(env_var(provider), sys_val),
          else: System.delete_env(env_var(provider))

        if app_val,
          do: Application.put_env(:optimal_system_agent, :"#{provider}_api_key", app_val),
          else: Application.delete_env(:optimal_system_agent, :"#{provider}_api_key")
      end

      {def_sys, def_app} = default_provider_snapshot

      if def_sys,
        do: System.put_env("OSA_DEFAULT_PROVIDER", def_sys),
        else: System.delete_env("OSA_DEFAULT_PROVIDER")

      if def_app,
        do: Application.put_env(:optimal_system_agent, :default_provider, def_app),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    :ok
  end

  setup do
    isolate_provider_env(self())
    :ok
  end

  # ---------------------------------------------------------------------------
  # P3: OpenAICompatProvider.resolve_api_key/2 falls back to System.get_env
  # ---------------------------------------------------------------------------

  describe "OpenAICompatProvider live api-key fallback (P3)" do
    test "resolves a key set ONLY via System.put_env (not Application config)" do
      refute Compat.resolved_api_key(:openrouter)

      System.put_env("OPENROUTER_API_KEY", "sk-live-only-test-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Compat.resolved_api_key(:openrouter) == "sk-live-only-test-key"
    end

    test "Application config still wins when both are present (no behavior change)" do
      System.put_env("GROQ_API_KEY", "sk-live-groq")
      Application.put_env(:optimal_system_agent, :groq_api_key, "sk-app-groq")

      on_exit(fn ->
        System.delete_env("GROQ_API_KEY")
        Application.delete_env(:optimal_system_agent, :groq_api_key)
      end)

      assert Compat.resolved_api_key(:groq) == "sk-app-groq"
    end

    test "a keyless local provider still gets its placeholder when no key is present anywhere" do
      assert Compat.resolved_api_key(:lmstudio) == "not-needed"
    end
  end

  # ---------------------------------------------------------------------------
  # P2/P3: Registry.provider_configured?/1 falls back live
  # ---------------------------------------------------------------------------

  describe "Registry.provider_configured?/1 live fallback (P2/P3)" do
    test "reports unconfigured before the key exists anywhere" do
      refute Registry.provider_configured?(:anthropic)
    end

    test "reports configured once a key is set live, without touching Application config" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-live-test")
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

      assert Registry.provider_configured?(:anthropic)
    end
  end

  # ---------------------------------------------------------------------------
  # P2: a lone live cloud key is preferred as the default provider over the
  # :ollama boot fallback
  # ---------------------------------------------------------------------------

  describe "Registry.resolved_default_provider/0 (P1/P2/F1)" do
    test "a lone live cloud key is selected as the default instead of :ollama" do
      # Simulate the exact fresh-daemon boot snapshot: no explicit provider
      # was set at boot, so config/runtime.exs's own cond fell through to the
      # :ollama catch-all.
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)

      # Simulate the CLI setup wizard subprocess writing ~/.osa/.env with a
      # key AFTER this (already-running) node booted — its System.put_env
      # here stands in for that live env becoming visible to this process
      # (the real fix also live-reads ~/.osa/.env; System.get_env is the
      # cheaper, deterministic path to exercise in a unit test).
      System.put_env("OPENAI_API_KEY", "sk-openai-live-test")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert Registry.resolved_default_provider() == :openai
    end

    test "falls back to the boot snapshot when no candidate has a live key" do
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      assert Registry.resolved_default_provider() == :ollama
    end

    test "falls back to the boot snapshot when MORE THAN ONE candidate has a live key (ambiguous)" do
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      System.put_env("OPENAI_API_KEY", "sk-openai-live-test")
      System.put_env("GROQ_API_KEY", "sk-groq-live-test")

      on_exit(fn ->
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("GROQ_API_KEY")
      end)

      assert Registry.resolved_default_provider() == :ollama
    end

    test "an explicit live OSA_DEFAULT_PROVIDER always wins, even over a boot snapshot for a different provider" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      System.put_env("OSA_DEFAULT_PROVIDER", "openrouter")
      on_exit(fn -> System.delete_env("OSA_DEFAULT_PROVIDER") end)

      assert Registry.resolved_default_provider() == :openrouter
    end

    test "a non-ollama boot snapshot is respected as-is when nothing explicit overrides it" do
      Application.put_env(:optimal_system_agent, :default_provider, :miosa)
      assert Registry.resolved_default_provider() == :miosa
    end
  end
end
