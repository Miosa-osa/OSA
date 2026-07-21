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
      if default_model, do: Application.put_env(:optimal_system_agent, :default_model, default_model),
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
end
