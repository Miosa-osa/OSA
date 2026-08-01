defmodule OptimalSystemAgent.Providers.UserKeyPathTest do
  @moduledoc """
  The path a user's own Anthropic / OpenAI API key travels, and the promise it
  must keep: pasting a key gives you either a working session or a clear "your
  key was rejected" — never a generic timeout, never a silent fallback to a
  different provider, and never the key being sent somewhere the user did not
  choose.

  Each test here corresponds to a specific way that promise was breakable.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Healing.ErrorClassifier
  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.{ErrorCatalog, FallbackChain, RetryClassifier}

  defp stub_name(tag), do: :"key_path_#{tag}_#{System.unique_integer([:positive])}"

  # ── A rejected key must SURFACE, not be papered over ──────────────────────

  describe "a rejected key never triggers a silent provider fallback" do
    # Previously these categories were excluded from fallback only by accident:
    # they were absent from @always_retryable_categories and survived purely
    # because a 401 body happened not to contain "timeout"/"connection"/"500".
    for reason <- [
          "Anthropic returned 401: invalid x-api-key",
          "HTTP 401: Incorrect API key provided: sk-abc",
          "ANTHROPIC_API_KEY not configured (no API key or OAuth token)",
          "OPENAI_API_KEY not configured"
        ] do
      test "no fallback for: #{reason}" do
        refute FallbackChain.retryable_error?(unquote(reason)),
               "an auth/config failure must surface to the user, not be " <>
                 "answered by a different provider"
      end
    end

    test "a 401 whose body contains a request id with 500 in it still does not fall back" do
      # The substring matcher reads bare digits, so `req_5004a` looked like a
      # 500 and would have been failed over to the next provider.
      reason = "HTTP 401: invalid x-api-key (request_id: req_5004a2f)"
      assert ErrorCatalog.classify(reason) in [:auth, :invalid_api_key]
      refute FallbackChain.retryable_error?(reason)
    end

    test "genuine transient faults DO still fall back" do
      assert FallbackChain.retryable_error?("HTTP 529: overloaded")
      assert FallbackChain.retryable_error?("HTTP 500: internal server error")
    end
  end

  describe "a rejected key is never retried" do
    for reason <- [
          "Anthropic returned 401: invalid x-api-key",
          "HTTP 401: Incorrect API key provided: sk-abc"
        ] do
      test "no retry for: #{reason}" do
        # retry_count 0 of 5 — the most favourable case for a retry.
        decision = RetryClassifier.classify(unquote(reason), 0, 5)

        assert match?({:emit_to_session, _}, decision) or match?({:fatal, _}, decision),
               "must not burn retries on a dead credential, got: #{inspect(decision)}"
      end
    end
  end

  describe "the healer treats a rejected key as fatal, not transient" do
    test "Anthropic's 'invalid x-api-key' wording is classified critical + non-retryable" do
      # This string matches neither "invalid api key" nor "unauthorized", and
      # bare "401" was missing from the list — so it used to fall through to
      # {:unknown, :medium, true} and the healer retried a dead key.
      assert {_kind, :critical, false} =
               ErrorClassifier.classify("returned 401: invalid x-api-key")
    end

    test "a bare 401 with no vendor name is still critical + non-retryable" do
      assert {_kind, :critical, false} = ErrorClassifier.classify("request failed with 401")
    end
  end

  # ── The health check must really talk to the API ──────────────────────────

  describe "health_check/1 reports a bad key clearly" do
    test "401 from Anthropic is reported as key_rejected, not a timeout" do
      name = stub_name(:anthropic_401)

      Req.Test.stub(name, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "bad key"}})
      end)

      assert {:error, %{verified: :key_rejected, error: "unauthorized"}} =
               Onboarding.health_check(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-wrong",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "a valid Anthropic key verifies OK" do
      name = stub_name(:anthropic_ok)

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "hi"}]})
      end)

      assert {:ok, %{verified: :ok}} =
               Onboarding.health_check(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-right",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "the Anthropic probe sends x-api-key and anthropic-version" do
      name = stub_name(:anthropic_headers)
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        send(test_pid, {:headers, conn.req_headers, conn.request_path})
        Req.Test.json(conn, %{"content" => []})
      end)

      Onboarding.health_check(%{
        "provider" => "anthropic",
        "api_key" => "sk-ant-xyz",
        "req_plug" => {Req.Test, name}
      })

      assert_receive {:headers, headers, path}
      assert path == "/v1/messages"
      assert {"x-api-key", "sk-ant-xyz"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end
  end

  describe "health_check/1 does not false-negative on reasoning models" do
    test "a reasoning model is probed with max_completion_tokens, not max_tokens" do
      # OpenAI reasoning models reject `max_tokens` with a 400. The probe used
      # to hardcode it, so a perfectly valid key checked against a reasoning
      # model came back "server_error" and the user was told setup failed.
      name = stub_name(:reasoning_body)
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, %{"choices" => []})
      end)

      Onboarding.health_check(%{
        "provider" => "openai",
        "api_key" => "sk-test",
        "model" => "gpt-5.6-terra",
        "req_plug" => {Req.Test, name}
      })

      assert_receive {:body, body}
      assert Map.has_key?(body, "max_completion_tokens")
      refute Map.has_key?(body, "max_tokens")
    end

    test "a non-reasoning model still uses max_tokens" do
      name = stub_name(:plain_body)
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, %{"choices" => []})
      end)

      Onboarding.health_check(%{
        "provider" => "openai",
        "api_key" => "sk-test",
        "model" => "gpt-4o",
        "req_plug" => {Req.Test, name}
      })

      assert_receive {:body, body}
      assert Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
    end
  end

  describe "a key is never sent to a provider the user did not choose" do
    test "an unrecognised provider with no base_url is refused, not routed to OpenAI" do
      # The allowlist admits providers with no request branch (gemini, azure,
      # bedrock, cohere, mistral, xai, groq, deepseek). The catch-all used to
      # default them to api.openai.com — POSTing e.g. a Google key to OpenAI.
      name = stub_name(:no_endpoint)

      Req.Test.stub(name, fn conn ->
        send(self(), :should_not_be_called)
        Req.Test.json(conn, %{})
      end)

      assert {:error, %{verified: :unverified, error: "no_endpoint"}} =
               Onboarding.health_check(%{
                 "provider" => "gemini",
                 "api_key" => "AIza-secret",
                 "req_plug" => {Req.Test, name}
               })

      refute_received :should_not_be_called
    end

    test "an unrecognised provider WITH a base_url is probed at that base_url" do
      name = stub_name(:custom_endpoint)
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        send(test_pid, {:host, conn.host, conn.request_path})
        Req.Test.json(conn, %{"choices" => []})
      end)

      Onboarding.health_check(%{
        "provider" => "custom",
        "api_key" => "sk-mine",
        "base_url" => "https://my-gateway.example.com/v1",
        "req_plug" => {Req.Test, name}
      })

      assert_receive {:host, host, path}
      assert host == "my-gateway.example.com"
      assert path == "/v1/chat/completions"
    end
  end
end
