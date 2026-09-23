defmodule OptimalSystemAgent.DefaultModelPersistenceTest do
  @moduledoc """
  Regression coverage for the "it always selects glm-5.2:cloud as default,
  randomly" bug report.

  ## Root cause

  `~/.osa/config.json` OUTRANKS `.env`'s `OLLAMA_MODEL`/`OSA_MODEL` at boot
  (`OptimalSystemAgent.Application.model_for_provider/3` - "config.json
  remains the user's PERSISTED selection ... so it still beats a possibly
  stale OLLAMA_MODEL env var"). That precedence is correct IF config.json is
  kept in sync with the user's latest choice. It was not: the in-TUI model
  picker wrote both `.env`-equivalent app-env keys AND `config.json` (via
  `OptimalSystemAgent.ModelSelection.persist/2`), but onboarding
  (`Onboarding.write_setup/1`, driven by `mix osa.setup.wizard`, the in-app
  `/setup` command, and the HTTP `/onboarding/setup` route) and the in-app
  `/setup` command (`CLI.Setup.write_config/3`) wrote ONLY `.env`.

  So a config.json left behind by ANY earlier picker selection permanently
  outranked every LATER onboarding/`/setup` choice, no matter how much more
  recent or deliberate that later choice was. Whether a user's setup choice
  "stuck" depended on accidental history (did a config.json happen to exist)
  rather than on intent - which is exactly the shape of "random" the bug
  report describes.

  These tests reproduce the exact operator scenario end-to-end: a stale
  config.json from an old picker choice, a fresh onboarding/`/setup` run that
  picks a DIFFERENT model, and the full boot-time precedence chain
  (`Application.resolve_provider/3` + `Application.model_for_provider/3`,
  exactly as `Application.start/2` calls them) - and lock in the fix: every
  "user chose a default" write path now syncs `config.json` through the same
  `ModelSelection.persist/2` the picker uses, so there is exactly one
  authoritative store and the freshest explicit choice always wins.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.{CLI, ConfigFile, Onboarding}
  alias OptimalSystemAgent.Application, as: App

  @app :optimal_system_agent
  @touched_app ~w(default_provider default_model ollama_model ollama_url ollama_api_key config_dir bootstrap_dir)a
  @touched_os ~w(OLLAMA_URL OLLAMA_MODEL OLLAMA_API_KEY OSA_DEFAULT_PROVIDER OSA_MODEL)

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "osa-default-model-persist-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", tmp)

    prev_app = Enum.map(@touched_app, &{&1, Application.get_env(@app, &1)})
    prev_os = Enum.map(@touched_os, &{&1, System.get_env(&1)})

    # `Onboarding.osa_dir/0` resolves `.env`/config.json off OSA_HOME.
    # `ConfigFile.config_dir/0` and `ModelSelection.persist_to_config/2`
    # resolve off `:config_dir`/`:bootstrap_dir` app env instead - at boot
    # `config/runtime.exs` keeps all three pointed at the same directory, so
    # mirror that alignment here or the fix under test would write config.json
    # to one directory while onboarding writes `.env` to another.
    Application.put_env(@app, :config_dir, tmp)
    Application.put_env(@app, :bootstrap_dir, tmp)
    ConfigFile.reload()

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      Enum.each(prev_app, fn
        {k, nil} -> Application.delete_env(@app, k)
        {k, v} -> Application.put_env(@app, k, v)
      end)

      Enum.each(prev_os, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  defp write_stale_config_json(tmp, provider, model) do
    File.write!(
      Path.join(tmp, "config.json"),
      Jason.encode!(%{"provider" => provider, "model" => model})
    )

    ConfigFile.reload()
  end

  # Mirrors EXACTLY what `Application.start/2` does (application.ex lines
  # ~99-150) to resolve the effective provider/model at boot, without booting
  # the whole OTP tree. Isolated on purpose so this test locks in the real
  # boot behavior, not a re-implementation of it.
  defp boot_resolve(env_default_provider, app_default_provider) do
    toml_model = ConfigFile.toml_model_section()

    provider = App.resolve_provider(toml_model, env_default_provider, app_default_provider)

    model =
      App.model_for_provider(provider, ConfigFile.model_name(), ConfigFile.provider()) ||
        App.ollama_env_model(provider, System.get_env("OLLAMA_MODEL")) ||
        Application.get_env(@app, :"#{provider}_model") ||
        Application.get_env(@app, :default_model)

    {provider, model}
  end

  describe "Onboarding.write_setup/1 keeps config.json in sync (the reported bug)" do
    test "a fresh onboarding model choice beats a stale config.json at boot", %{tmp: tmp} do
      # Operator's disk, reproduced: an OLD picker/onboarding pass left
      # config.json pinned to glm-5.2:cloud.
      write_stale_config_json(tmp, "ollama", "glm-5.2:cloud")
      assert ConfigFile.model_name() == "glm-5.2:cloud"

      # Operator re-runs setup (2026-09-22 in the bug report) and picks a
      # DIFFERENT model.
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "ollama_cloud",
                 "model" => "glm-5.3-flash:cloud",
                 "api_key" => "test-key"
               })

      # config.json must reflect the NEW choice, not the stale one.
      ConfigFile.reload()
      assert ConfigFile.model_name() == "glm-5.3-flash:cloud"
      assert ConfigFile.provider() == "ollama"

      # And the exact boot-time resolution chain application.ex runs must
      # resolve to the fresh choice, not the stale glm-5.2:cloud.
      assert {:ollama, "glm-5.3-flash:cloud"} = boot_resolve("ollama", :ollama)
    end

    test "config.json is untouched when no model was chosen (api-key-only update)", %{tmp: tmp} do
      write_stale_config_json(tmp, "ollama", "glm-5.2:cloud")

      assert :ok =
               Onboarding.write_setup(%{"provider" => "ollama_cloud", "api_key" => "test-key"})

      ConfigFile.reload()
      # No model was supplied - the existing selection must survive untouched,
      # not get clobbered with a blank/placeholder value.
      assert ConfigFile.model_name() == "glm-5.2:cloud"
    end

    test "switching provider without a model does not misapply the old provider's config.json model",
         %{tmp: tmp} do
      write_stale_config_json(tmp, "ollama", "glm-5.2:cloud")

      assert :ok =
               Onboarding.write_setup(%{"provider" => "anthropic", "api_key" => "test-key"})

      # config.json's model was persisted under "ollama" and must not be
      # stapled onto anthropic (Application.model_for_provider/3 is provider-scoped).
      assert {:anthropic, model} = boot_resolve("anthropic", :ollama)
      refute model == "glm-5.2:cloud"
    end
  end

  describe "CLI.Setup.write_config/3 keeps config.json in sync" do
    test "an in-app /setup model choice beats a stale config.json at boot", %{tmp: tmp} do
      write_stale_config_json(tmp, "ollama", "glm-5.2:cloud")

      assert :ok =
               CLI.Setup.write_config(:ollama_cloud, "test-key", model: "glm-5.3-flash:cloud")

      ConfigFile.reload()
      assert ConfigFile.model_name() == "glm-5.3-flash:cloud"
      assert ConfigFile.provider() == "ollama"

      assert {:ollama, "glm-5.3-flash:cloud"} = boot_resolve("ollama", :ollama)
    end
  end
end
