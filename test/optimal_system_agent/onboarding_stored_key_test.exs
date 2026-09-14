defmodule OptimalSystemAgent.OnboardingStoredKeyTest do
  @moduledoc """
  A key PASTED IN THE APP must be as visible to the picker as one in the
  environment.

  MEASURED 2026-09-11 against a live daemon: `/api/v1/providers/` reported
  Surplus `connected: true` while `/onboarding/status` — the endpoint the model
  picker actually reads — reported `auth_state: "needs_key"` for the same
  provider at the same moment. Two readers of one credential disagreeing.

  Cause: `detect_key/2` consulted `System.get_env/1` alone. A key pasted into
  the picker is written by `ProviderRoutes.store_api_key/2` to
  `$OSA_HOME/config.json` under `api_keys`, and never reaches the environment —
  so `detected` omitted the provider, `is_ready/1` returned false, the row kept
  its "needs key" badge, and Enter reopened the key screen instead of showing
  models. The user could not reach the model list at all.

  That also explains the inconsistency reported as "sometimes it works": a key
  in `$OSA_HOME/.env` IS found, because the launcher sources that file into the
  environment before the backend boots. `.env` keys worked; pasted keys never
  did.

  These tests pin the stored-key path directly, with the environment variable
  explicitly cleared, so a regression cannot hide behind an ambient key.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding

  @provider "openai"
  @env_var "OPENAI_API_KEY"

  setup do
    home = Path.join(System.tmp_dir!(), "osa-stored-key-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    prev_bootstrap = Application.get_env(:optimal_system_agent, :bootstrap_dir)
    prev_env = System.get_env(@env_var)
    Application.put_env(:optimal_system_agent, :bootstrap_dir, home)
    # The whole point: only the CONFIG FILE may make this provider detected.
    System.delete_env(@env_var)

    on_exit(fn ->
      restore(:bootstrap_dir, prev_bootstrap)
      restore_env(@env_var, prev_env)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp restore_env(_var, nil), do: :ok
  defp restore_env(var, value), do: System.put_env(var, value)

  defp write_keys!(home, keys) do
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"api_keys" => keys}))
  end

  defp detected_ids do
    Onboarding.detect_existing().detected |> Enum.map(& &1.provider)
  end

  describe "a key stored in config.json is detected" do
    test "a pasted key makes its provider detected with no env var set", %{home: home} do
      refute System.get_env(@env_var), "precondition: the env var must be absent"

      write_keys!(home, %{@provider => "sk-pasted-in-app-1234"})

      assert @provider in detected_ids(),
             "a key pasted in the app must make its provider detected. It is " <>
               "written to config.json, not the environment, so env-only " <>
               "detection cannot see it - and the picker then refuses to open " <>
               "the model list for a provider the user has already configured."
    end

    test "it reports where the key came from", %{home: home} do
      write_keys!(home, %{@provider => "sk-pasted-in-app-1234"})

      entry =
        Onboarding.detect_existing().detected
        |> Enum.find(&(&1.provider == @provider))

      assert entry, "expected #{@provider} to be detected from the stored key"

      assert entry.source == "config",
             "the source must distinguish a stored key from an environment one, " <>
               "so a support question ('where is it reading that from?') has an answer"

      # Never the key itself - a preview is the only thing allowed out.
      refute entry.key_preview =~ "pasted-in-app"
    end

    test "the environment still wins when both are present", %{home: home} do
      write_keys!(home, %{@provider => "sk-from-config"})
      System.put_env(@env_var, "sk-from-environment")

      entry =
        Onboarding.detect_existing().detected
        |> Enum.find(&(&1.provider == @provider))

      assert entry.source == "environment",
             "an env key is the more specific statement of intent and must keep " <>
               "winning, exactly as it did before stored keys were consulted"
    end

    test "an empty stored value is not a key", %{home: home} do
      write_keys!(home, %{@provider => ""})

      refute @provider in detected_ids(),
             "an empty string is an absent key, not a configured provider"
    end

    test "a malformed config file degrades to 'no stored keys'", %{home: home} do
      File.write!(Path.join(home, "config.json"), "{not json")

      # Must not raise: a corrupt config is a reason to show the key screen,
      # not a reason for the picker to fail to open at all.
      refute @provider in detected_ids()
    end

    test "a missing config file degrades to 'no stored keys'", %{home: home} do
      refute File.exists?(Path.join(home, "config.json"))
      refute @provider in detected_ids()
    end
  end
end
