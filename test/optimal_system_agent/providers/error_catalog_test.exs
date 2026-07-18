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
    test "auth errors point at /login" do
      assert Catalog.user_message("Anthropic returned 401: unauthorized") =~ "/login"
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
end
