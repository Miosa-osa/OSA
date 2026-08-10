defmodule OptimalSystemAgent.Providers.ErrorCatalogTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ErrorCatalog, as: Catalog

  describe "classify/1" do
    test "auth and key errors" do
      assert Catalog.classify("Anthropic returned 401: unauthorized") == :auth
      assert Catalog.classify("Anthropic returned 401: invalid x-api-key") == :invalid_api_key
      assert Catalog.classify("OAuth token has been revoked") == :token_revoked
    end

    test "model, rate, and capacity errors" do
      assert Catalog.classify("Anthropic returned 404: model_not_found") == :model_not_found
      assert Catalog.classify({:rate_limited, 30}) == :rate_limit
      assert Catalog.classify({:http_error, 529, "overloaded_error"}) == :server_overload
      assert Catalog.classify({:stream_error, "overloaded_error"}) == :server_overload
      assert Catalog.classify({:http_error, 503, "service unavailable"}) == :server_error
    end

    test "prompt, billing, connection, and SSL errors" do
      assert Catalog.classify("prompt is too long: 210000 tokens > 200000 maximum") ==
               :context_overflow

      assert Catalog.classify("Your credit balance is too low") == :credit_balance
      assert Catalog.classify("Anthropic connection failed: :econnrefused") == :connection_error
      assert Catalog.classify("TLS error: unable_to_verify_leaf_signature") == :ssl_error
      assert Catalog.classify("something entirely novel") == :unknown
    end
  end

  describe "user_message/1" do
    test "auth errors point at `osa setup`" do
      # Was "/login" — that command no longer authenticates anything now that
      # the Anthropic subscription sign-in is removed; OSA is API-key only.
      assert Catalog.user_message("Anthropic returned 401: unauthorized") =~ "osa setup"
      refute Catalog.user_message("Anthropic returned 401: unauthorized") =~ "/login"
    end

    test "model errors point at /model" do
      assert Catalog.user_message("Anthropic returned 404: not_found_error") =~ "/model"
    end

    test "rate limit surfaces the reset time" do
      msg = Catalog.user_message({:rate_limited, 90})
      assert msg =~ "429"
      assert msg =~ "1m"
    end

    test "prompt too long points at /compact" do
      assert Catalog.user_message("maximum context length exceeded") =~ "/compact"
    end

    test "unknown errors keep the raw reason and stay actionable" do
      msg = Catalog.user_message("weird failure xyz")
      assert msg =~ "weird failure xyz"
      assert msg =~ "API Error"
    end
  end

  describe "missing API key (no-key handling)" do
    test "classifies our own pre-flight not-configured errors as missing_api_key" do
      assert Catalog.classify("ANTHROPIC_API_KEY not configured") == :missing_api_key
      assert Catalog.classify("OPENAI_API_KEY not configured") == :missing_api_key
      assert Catalog.classify("API key not configured") == :missing_api_key
      assert Catalog.classify("No API key provided") == :missing_api_key
      assert Catalog.classify("api key is required") == :missing_api_key
    end

    test "missing-key is distinct from an invalid-key 401" do
      # A rejected key (401) still routes to invalid_api_key / auth, not
      # missing_api_key; the guidance differs (re-auth vs add a key).
      assert Catalog.classify("Anthropic returned 401: invalid x-api-key") == :invalid_api_key
      refute Catalog.classify("Anthropic returned 401: invalid x-api-key") == :missing_api_key
    end

    test "message names the exact env var and provider, and every fix path" do
      msg = Catalog.user_message("ANTHROPIC_API_KEY not configured")
      assert msg =~ "Anthropic"
      assert msg =~ "ANTHROPIC_API_KEY"
      assert msg =~ "osa setup"
      refute msg =~ "/login"
      # Must NOT tell the user to "try again" as if it were transient, and must
      # not misfile a no-key error under a generic retry hint.
      refute msg =~ "switch models"
    end

    test "message falls back to generic guidance when no env var is present" do
      msg = Catalog.user_message("API key not configured")
      assert msg =~ "osa setup"
      assert msg =~ "No API key configured"
    end

    test "P4: Anthropic's own no-key phrasing classifies as missing_api_key" do
      # anthropic.ex resolve_auth/0's error when no API key is present.
      # Previously read "No Anthropic API key or OAuth token configured."
      # which never matched the "not configured" substring the
      # missing_api_key? guard looks for (the word "not" never appears), so
      # it fell through to :unknown and skipped the actionable `osa setup`
      # guidance for the provider a Claude-first user is most likely to hit
      # first. (The OAuth half of that message is gone — Anthropic is
      # API-key only now; see Auth.LegacyAnthropicOAuth.)
      reason = "ANTHROPIC_API_KEY not configured. Run `osa setup` or set ANTHROPIC_API_KEY."
      assert Catalog.classify(reason) == :missing_api_key

      msg = Catalog.user_message(reason)
      assert msg =~ "Anthropic"
      assert msg =~ "ANTHROPIC_API_KEY"
      assert msg =~ "osa setup"
    end
  end

  describe "P1: connection_error names Ollama instead of a generic internet message" do
    test "an Ollama-sourced connection failure gets an Ollama-named, actionable message" do
      reason = "Ollama connection failed: :econnrefused"
      assert Catalog.classify(reason) == :connection_error

      msg = Catalog.user_message(reason)
      assert msg =~ "Ollama"
      assert msg =~ "ollama serve"
      assert msg =~ "osa setup"
      # Must not degrade to the misleading generic guidance that drops the
      # word "Ollama" entirely.
      refute msg =~ "Check your internet connection"
    end

    test "a non-Ollama connection failure keeps the generic internet/proxy guidance" do
      reason = "Anthropic connection failed: :econnrefused"
      msg = Catalog.user_message(reason)
      assert msg =~ "internet connection"
      refute msg =~ "Ollama"
    end
  end

  describe "model-not-found (404) is a CLEAR, actionable, non-retryable error (finding #9)" do
    test "classifies as :model_not_found for the common phrasings" do
      assert Catalog.classify("Anthropic returned 404: not_found_error") == :model_not_found
      assert Catalog.classify({:http_error, 404, "model not found"}) == :model_not_found
      assert Catalog.classify("invalid model name: gpt-99") == :model_not_found
    end

    test "message names the offending provider when recoverable from the reason" do
      msg = Catalog.user_message("Anthropic returned 404: not_found_error: model: bogus")
      assert msg =~ "Anthropic"
      assert msg =~ "/model"
      assert msg =~ "404"
    end

    test "message falls back to generic guidance when no provider prefix is present" do
      msg = Catalog.user_message({:http_error, 404, "model not found"})
      assert msg =~ "/model"
      assert msg =~ "API Error"
    end
  end
end
