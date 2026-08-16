defmodule OptimalSystemAgent.Providers.UncensoredProviderTest do
  @moduledoc """
  Locks in the `uncensored` provider wiring.

  The interesting property is the auth header. api.uncensored.com reads
  `x-api-key` and ignores `Authorization: Bearer` — and it ignores it
  *silently*, answering a Bearer-authenticated call exactly as it answers an
  unauthenticated one. A regression here would therefore not look like an auth
  bug, it would look like the user's key being invalid, so it is worth a test.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.OpenAICompatProvider
  alias OptimalSystemAgent.Providers.Registry

  describe "build_headers/2 auth style" do
    test "defaults to the OpenAI Bearer convention" do
      headers = OpenAICompat.build_headers("sk-abc", [])

      assert {"Authorization", "Bearer sk-abc"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
    end

    test "an unknown auth style falls back to Bearer rather than sending nothing" do
      headers = OpenAICompat.build_headers("sk-abc", auth_style: :something_new)

      assert {"Authorization", "Bearer sk-abc"} in headers
    end

    test ":x_api_key sends x-api-key and no Authorization header at all" do
      headers = OpenAICompat.build_headers("sk-abc", auth_style: :x_api_key)

      assert {"x-api-key", "sk-abc"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
    end

    test "content-type and extra_headers survive both auth styles" do
      for style <- [:bearer, :x_api_key] do
        headers =
          OpenAICompat.build_headers("sk-abc",
            auth_style: style,
            extra_headers: [{"X-Title", "OSA"}]
          )

        assert {"Content-Type", "application/json"} in headers
        assert {"X-Title", "OSA"} in headers
      end
    end
  end

  describe "provider config" do
    test "uncensored is registered and routes through the compat provider" do
      assert :uncensored in Registry.list_providers()
      assert :uncensored in OpenAICompatProvider.providers()
    end

    test "carries the x-api-key auth style and the /api/v1 base URL" do
      assert OpenAICompatProvider.auth_style(:uncensored) == :x_api_key
      assert OpenAICompatProvider.base_url(:uncensored) == "https://api.uncensored.com/api/v1"
    end

    test "the default model is one of the advertised models" do
      assert OpenAICompatProvider.default_model(:uncensored) in
               OpenAICompatProvider.available_models(:uncensored)
    end

    test "no other compat provider was switched off Bearer by this change" do
      for provider <- OpenAICompatProvider.providers(), provider != :uncensored do
        assert OpenAICompatProvider.auth_style(provider) == :bearer,
               "#{provider} unexpectedly changed auth style"
      end
    end
  end
end
