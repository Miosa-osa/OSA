defmodule OptimalSystemAgent.CLI.SetupAuthForkTest do
  @moduledoc """
  The setup surfaces' end of the dual-mode fork.

  The property that matters is that `osa setup`, `mix osa.setup.wizard` and
  the TUI all reach the fork through the *same* pure decision functions. If
  each surface grew its own notion of which providers support sign-in they
  would drift, which is the specific failure observed in the tool this was
  modelled on — three capability lists that disagreed with each other.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.CLI.Setup
  alias OptimalSystemAgent.Onboarding

  describe "the provider picker" do
    test "is populated from the catalog rather than being nil" do
      # Regression: this call site read `@providers`, an undefined module
      # attribute that silently evaluates to nil, so the in-app `/setup`
      # picker was handed nil instead of the provider catalog.
      providers = Setup.providers()

      assert is_list(providers)
      assert length(providers) > 10

      for p <- providers do
        assert is_atom(p.value)
        assert is_binary(p.label) and p.label != ""
      end
    end

    test "offers the ChatGPT plan entry, routed to a provider the Registry knows" do
      assert Enum.any?(Setup.providers(), &(&1.value == :openai_codex))
      assert {:ok, :openai_codex} = Onboarding.known_provider_atom("openai_codex")
    end

    test "every picker entry maps to a routable provider" do
      # A provider you can select but never use is worse than one that is
      # absent.
      for %{value: value} <- Setup.providers(), value != :custom do
        id = if value == :ollama, do: "ollama_local", else: to_string(value)

        assert {:ok, _} = Onboarding.known_provider_atom(Onboarding.runtime_provider_id(id)),
               "picker offers '#{value}' but the Registry cannot route it"
      end
    end
  end

  describe "which providers reach the fork" do
    test "key-only providers show no auth menu on any surface" do
      for id <- ~w(anthropic openai groq google mistral cohere deepseek openrouter) do
        assert Onboarding.auth_options(id) == [],
               "#{id} would now show an auth-method menu it did not show before"
      end
    end

    test "a sign-in-only provider does not fall back to prompting for a key" do
      # `openai_codex` accepts no API key — an OpenAI key belongs on the
      # `openai` entry, billed per-token against the endpoint that accepts it.
      # Defaulting to `:api_key` here would prompt for a credential the
      # provider cannot use.
      modes = Onboarding.usable_auth_modes("openai_codex")

      assert modes == [:oauth]
      assert Onboarding.auth_route_for(modes, nil) == :oauth
      assert Onboarding.auth_route_for(modes, :api_key) == :oauth
    end

    test "a key-only provider resolves to the key path whatever is requested" do
      modes = Onboarding.usable_auth_modes("anthropic")

      assert Onboarding.auth_route_for(modes, nil) == :api_key
      assert Onboarding.auth_route_for(modes, :oauth) == :api_key
    end
  end

  describe "health check for a subscription provider" do
    setup do
      dir = Path.join(System.tmp_dir!(), "osa-setupfork-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      prev = System.get_env("OSA_HOME")
      System.put_env("OSA_HOME", dir)

      on_exit(fn ->
        if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
        File.rm_rf(dir)
      end)

      :ok
    end

    test "reports 'not signed in' with an action, rather than a missing endpoint" do
      assert {:error, %{error: "not_connected", message: message}} =
               Onboarding.health_check(%{"provider" => "openai_codex"})

      assert message =~ "Sign in"
    end

    test "reports a connected plan without making a network call" do
      OptimalSystemAgent.Auth.SubscriptionStore.put("openai_codex", %{
        "access_token" => "t",
        "plan_type" => "pro",
        "expires_at" => System.system_time(:second) + 86_400
      })

      # No stub is installed; a network call here would fail the test.
      assert {:ok, %{status: "connected", plan: "pro", auth_mode: "subscription"}} =
               Onboarding.health_check(%{"provider" => "openai_codex"})
    end

    test "an expired sign-in is distinguished from never having signed in" do
      OptimalSystemAgent.Auth.SubscriptionStore.put("openai_codex", %{
        "access_token" => "t",
        "expires_at" => System.system_time(:second) - 1
      })

      assert {:error, %{error: "sign_in_expired"}} =
               Onboarding.health_check(%{"provider" => "openai_codex"})
    end
  end
end
