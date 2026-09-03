defmodule OptimalSystemAgent.Providers.RegistryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Registry

  # ---------------------------------------------------------------------------
  # Module smoke tests
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Registry module is defined and loaded" do
      assert Code.ensure_loaded?(Registry)
    end

    test "exports list_providers/0" do
      assert function_exported?(Registry, :list_providers, 0)
    end

    test "exports provider_info/1" do
      assert function_exported?(Registry, :provider_info, 1)
    end

    test "exports chat/2" do
      assert function_exported?(Registry, :chat, 2)
    end

    test "exports provider_configured?/1" do
      assert function_exported?(Registry, :provider_configured?, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # should_fallback?/1 — sync-path fallback gate (finding #9 / #P4)
  # ---------------------------------------------------------------------------

  describe "should_fallback?/1" do
    test "genuinely transient errors warrant a cross-provider re-send" do
      assert Registry.should_fallback?({:http_error, 503, "service unavailable"})
      assert Registry.should_fallback?({:http_error, 500, "internal server error"})
      assert Registry.should_fallback?({:rate_limited, 10})
    end

    test "model-not-found (404) does NOT warrant a re-send — it's a config error" do
      refute Registry.should_fallback?({:http_error, 404, "not_found_error"})
      refute Registry.should_fallback?("Anthropic returned 404: not_found_error")
    end

    test "context-overflow does NOT warrant a re-send — identical failure on every provider" do
      refute Registry.should_fallback?("prompt is too long for this model")
    end

    test "missing/invalid API key and auth errors do NOT warrant a re-send" do
      refute Registry.should_fallback?("ANTHROPIC_API_KEY not configured")
      refute Registry.should_fallback?({:http_error, 401, "invalid x-api-key"})
      refute Registry.should_fallback?({:http_error, 403, "forbidden"})
    end
  end

  # ---------------------------------------------------------------------------
  # list_providers/0 smoke tests
  # ---------------------------------------------------------------------------

  describe "list_providers/0" do
    test "returns a non-empty list of atoms" do
      providers = Registry.list_providers()
      assert is_list(providers)
      assert length(providers) > 0
      Enum.each(providers, fn p -> assert is_atom(p) end)
    end

    test "includes the expected core providers" do
      providers = Registry.list_providers()
      assert :ollama in providers
      assert :anthropic in providers
      assert :openai in providers
      assert :groq in providers
    end
  end

  # ---------------------------------------------------------------------------
  # provider_info/1 smoke tests
  # ---------------------------------------------------------------------------

  describe "provider_info/1" do
    test "returns ok tuple with expected fields for a known provider" do
      assert {:ok, info} = Registry.provider_info(:ollama)
      assert info.name == :ollama
      assert is_atom(info.module)
      assert is_binary(info.default_model)
      assert is_boolean(info.configured?)
    end

    test "returns error tuple for an unknown provider" do
      assert {:error, reason} = Registry.provider_info(:no_such_provider_xyz)
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # provider_configured?/1 smoke tests
  # ---------------------------------------------------------------------------

  describe "provider_configured?/1" do
    test "account sign-in configures every subscription-backed provider" do
      home = Path.join(System.tmp_dir!(), "osa-registry-account-#{System.unique_integer([:positive])}")
      previous_home = System.get_env("OSA_HOME")
      System.put_env("OSA_HOME", home)

      on_exit(fn ->
        if previous_home, do: System.put_env("OSA_HOME", previous_home), else: System.delete_env("OSA_HOME")
        File.rm_rf(home)
      end)

      refute Registry.provider_configured?(:openai_codex)

      assert :ok =
               OptimalSystemAgent.Auth.SubscriptionStore.put("openai_codex", %{
                 "access_token" => "test-token"
               })

      assert Registry.provider_configured?(:openai_codex)
    end

    test "ollama configured? returns a boolean (no API key required)" do
      # Ollama checks TCP reachability rather than an API key.
      # In CI or test environments Ollama may not be running, so we only
      # assert the return type, not a specific value.
      assert is_boolean(Registry.provider_configured?(:ollama))
    end

    test "returns a boolean for any provider atom" do
      result = Registry.provider_configured?(:anthropic)
      assert is_boolean(result)
    end

    test "returns false for an unconfigured/unknown provider" do
      # A nonsense provider name will have no API key set in the test env
      assert Registry.provider_configured?(:zzz_fake_provider_xyz) == false
    end
  end

  # ---------------------------------------------------------------------------
  # chat/2 — returns error for unknown provider (no real LLM call)
  # ---------------------------------------------------------------------------

  describe "chat/2" do
    test "returns error tuple for an unknown provider" do
      messages = [%{role: "user", content: "hello"}]
      assert {:error, reason} = Registry.chat(messages, provider: :zzz_nonexistent)
      assert is_binary(reason)
      assert reason =~ "Unknown provider"
    end
  end
end
