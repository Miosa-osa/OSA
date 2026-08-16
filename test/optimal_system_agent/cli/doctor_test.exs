defmodule OptimalSystemAgent.CLI.DoctorTest do
  @moduledoc """
  Regression coverage for the `osa doctor` provider-model mismatch bug:

  `check_provider/0` used to print the FIRST model returned by Ollama's
  `/api/tags` instead of the actually-configured `OSA_MODEL` (which `/health`
  reports correctly via `Application.get_env(:optimal_system_agent,
  :default_model)`, falling back to the provider's catalog default). This
  meant `osa doctor` and `/health` could disagree about which model OSA is
  actually going to use.

  `configured_model_name/1` is the shared resolver extracted so doctor and
  `/health` (`lib/optimal_system_agent/channels/http.ex` ~L97-116) agree —
  these tests exercise it directly since it needs no network/TTY.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Doctor

  setup do
    default_model = Application.get_env(:optimal_system_agent, :default_model)
    default_provider = Application.get_env(:optimal_system_agent, :default_provider)

    on_exit(fn ->
      if default_model,
        do: Application.put_env(:optimal_system_agent, :default_model, default_model),
        else: Application.delete_env(:optimal_system_agent, :default_model)

      if default_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, default_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    Application.delete_env(:optimal_system_agent, :default_model)
    Application.delete_env(:optimal_system_agent, :default_provider)
    :ok
  end

  describe "configured_model_name/1" do
    test "reports the explicitly configured OSA_MODEL (default_model), not an arbitrary detected model" do
      Application.put_env(:optimal_system_agent, :default_model, "glm-5.2:cloud")

      assert Doctor.configured_model_name(:ollama) == "glm-5.2:cloud"
    end

    test "falls back to the provider's catalog default model when none is explicitly configured" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

      # No :default_model set — must resolve via Providers.Registry.provider_info/1,
      # exactly like /health does, NOT an arbitrary value.
      {:ok, info} = OptimalSystemAgent.Providers.Registry.provider_info(:anthropic)

      assert Doctor.configured_model_name(:anthropic) == to_string(info.default_model)
    end

    test "an explicitly configured model always wins over the provider default" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :default_model, "custom-pinned-model")

      assert Doctor.configured_model_name(:anthropic) == "custom-pinned-model"
    end

    test "never raises for an unknown provider — falls back to the provider name itself" do
      assert Doctor.configured_model_name(:totally_unknown_provider) ==
               "totally_unknown_provider"
    end
  end

  # The bug: `check_provider/0` probed Ollama FIRST and reported whichever
  # provider answered, then paired it with the CONFIGURED model. A box with
  # OSA_DEFAULT_PROVIDER=anthropic, OSA_MODEL=claude-opus-5 and any listening
  # Ollama printed "Ollama (claude-opus-5)" — a pairing in no config file,
  # describing a request Ollama could never serve. Configuration is the
  # identity; reachability only qualifies it.
  describe "check_provider/0 — identity, not reachability" do
    setup do
      previous = Application.get_env(:optimal_system_agent, :anthropic_api_key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:optimal_system_agent, :anthropic_api_key, previous),
          else: Application.delete_env(:optimal_system_agent, :anthropic_api_key)
      end)

      :ok
    end

    test "names the CONFIGURED provider, never a different one that merely answers a ping" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :default_model, "claude-opus-5")
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-test-not-dialled")

      assert {status, "Provider", detail} = Doctor.check_provider()
      assert detail =~ "Anthropic"
      assert detail =~ "claude-opus-5"
      # The whole point: a reachable Ollama must not rename the configured provider.
      refute detail =~ "Ollama"
      assert status == :pass
    end

    test "agrees with check_model/0 and /health, because both resolve via Runtime.Identity" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :default_model, "claude-opus-5")
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-test-not-dialled")

      {_status, "Provider", detail} = Doctor.check_provider()

      assert detail =~ OptimalSystemAgent.Runtime.Identity.model()
      assert Doctor.configured_model_name(:anthropic) == "claude-opus-5"
    end

    test "a configured provider with no credential FAILS by name — it does not fall through to another" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      Application.put_env(:optimal_system_agent, :default_model, "claude-opus-5")
      Application.delete_env(:optimal_system_agent, :anthropic_api_key)

      # Only meaningful when no live ANTHROPIC_API_KEY is present on this box.
      if OptimalSystemAgent.Providers.Registry.provider_configured?(:anthropic) do
        assert {:pass, "Provider", _} = Doctor.check_provider()
      else
        assert {:fail, "Provider", detail} = Doctor.check_provider()
        assert detail =~ "no credential found for anthropic"
        refute detail =~ "Ollama"
      end
    end

    test "nothing configured is never a :pass — it says so instead of claiming a provider is in use" do
      Application.delete_env(:optimal_system_agent, :default_provider)
      Application.delete_env(:optimal_system_agent, :default_model)

      assert {status, "Provider", detail} = Doctor.check_provider()
      refute status == :pass, "an unconfigured box must not report a provider as configured"

      if status == :optional do
        assert detail =~ "none configured"
      end
    end
  end

  describe "api_status/2 — the three port states" do
    test "OSA responding is a pass" do
      assert {:pass, "API", detail} = Doctor.api_status(:osa, 9089)
      assert detail =~ "OSA responding"
    end

    test "port free (OSA not running) is a fail that tells you to start it" do
      assert {:fail, "API", detail} = Doctor.api_status(:free, 9089)
      assert detail =~ "not running"
    end

    test "port held by a foreign process is a fail with the actionable fix (the old blind spot)" do
      assert {:fail, "API", detail} = Doctor.api_status(:foreign, 9089)
      assert detail =~ "in use by another process"
      assert detail =~ "ss -ltnp"
      assert detail =~ "OSA_HTTP_PORT"
    end
  end
end
