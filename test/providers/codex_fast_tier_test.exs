defmodule OptimalSystemAgent.Providers.CodexFastTierTest do
  @moduledoc """
  `/fast` against a ChatGPT plan, asserted at the wire.

  The ChatGPT Codex endpoint answers an unsupported request field with an
  EMPTY HTTP 400: no code, no message, nothing to match on. `service_tier` is
  such a field there even though the public Responses API accepts it, so a
  `/fast` turn died at the boundary and, because `/fast` is a persistent
  per-session toggle, so did every turn after it. The tier-less retry could not
  save the turn either, since the reason string it was handed was `"HTTP 400: "`
  and no tier vocabulary appears in that.

  These tests therefore assert the BODY that leaves OSA rather than the opts a
  call site assembles: the fallback hop from `openai` to `openai_codex` carries
  the tier along too (`Registry.cross_provider_opts/1` drops only `:model`), so
  the only claim worth making is about what reaches the endpoint.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Providers.OpenAICodex

  @ok_response %{
    "output" => [
      %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
    ],
    "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-codex-fast-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    SubscriptionStore.put("openai_codex", %{
      "access_token" => "tok",
      "account_id" => "acct_1",
      # An hour of runway, so nothing proactive fires and the test exercises
      # the request path rather than the refresh path.
      "expires_at" => System.system_time(:second) + 3600,
      "base_url" => "https://stub.invalid/backend-api/codex"
    })

    :ok
  end

  # Captures the encoded request body and answers with a minimal Responses
  # success, so a stripped field shows up as a missing key rather than as a
  # transport error that could have any number of causes.
  defp capture do
    test = self()

    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:wire_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(@ok_response))
    end
  end

  describe "the Codex request boundary" do
    test "a /fast turn puts no service_tier on the wire" do
      assert {:ok, %{content: "ok"}} =
               OpenAICodex.chat([%{role: "user", content: "hi"}],
                 service_tier: "priority",
                 max_tokens: 4096,
                 req_options: [plug: capture(), retry: false]
               )

      assert_received {:wire_body, body}
      refute Map.has_key?(body, "service_tier")
      # The field this endpoint was already known to reject the same way. Both
      # deletions live in the same place for the same reason.
      refute Map.has_key?(body, "max_output_tokens")
      assert body["store"] == false
    end

    test "the streaming path strips it too" do
      assert :ok =
               OpenAICodex.chat_stream(
                 [%{role: "user", content: "hi"}],
                 fn _event -> :ok end,
                 service_tier: "priority",
                 max_tokens: 4096,
                 req_options: [plug: capture(), retry: false]
               )

      assert_received {:wire_body, body}
      refute Map.has_key?(body, "service_tier")
      assert body["stream"] == true
    end
  end

  describe "an empty 4xx is readable as a refused tier" do
    test "a 4xx with no detail at all is recognized" do
      assert LLMClient.bodyless_client_error?("HTTP 400: ")
      assert LLMClient.bodyless_client_error?("HTTP 400:")
      assert LLMClient.bodyless_client_error?("HTTP 422: ")
    end

    test "a 4xx that explains itself keeps its own meaning" do
      refute LLMClient.bodyless_client_error?("HTTP 400: invalid tool schema")
      refute LLMClient.bodyless_client_error?("HTTP 403: account suspended")
    end

    test "server errors and untagged reasons are left alone" do
      refute LLMClient.bodyless_client_error?("HTTP 500: ")
      refute LLMClient.bodyless_client_error?("Connection failed: timed out")
      refute LLMClient.bodyless_client_error?({:rate_limited, 30})
      refute LLMClient.bodyless_client_error?(nil)
    end

    test "the vocabulary matcher still refuses to classify it on its own" do
      # Which is why the empty-400 case is read only where a `service_tier` is
      # already known to have been attached to the request: on any other
      # request that same reason means something else entirely.
      refute LLMClient.tier_rejection?("HTTP 400: ")
    end
  end
end
