defmodule OptimalSystemAgent.Auth.Providers.QwenTest do
  @moduledoc """
  Qwen account sign-in — the second mode on the EXISTING `qwen` row.

  Two things here are Qwen-specific and are the reason this is not a copy of
  the xAI file:

    * the grant is **PKCE-bound**. The challenge must reach the device
      authorization request and the matching verifier must reach the token
      exchange, or the exchange is refused — so both legs are inspected on the
      wire rather than assumed.
    * the inference endpoint is **derived per account** from the
      `resource_url` the provider returns, not from a constant.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.PKCE
  alias OptimalSystemAgent.Auth.Providers.Qwen
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.OpenAICompatProvider

  @dashscope "https://dashscope.aliyuncs.com/compatible-mode/v1"
  @portal "https://portal.qwen.ai/v1"

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-qwen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    prev_key = System.get_env("QWEN_API_KEY")
    System.put_env("OSA_HOME", dir)
    System.delete_env("QWEN_API_KEY")
    Application.put_env(:optimal_system_agent, :live_env_file_fallback, false)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_key,
        do: System.put_env("QWEN_API_KEY", prev_key),
        else: System.delete_env("QWEN_API_KEY")

      for k <- [:auth_req_options, :qwen_api_key, :qwen_url, :live_env_file_fallback] do
        Application.delete_env(:optimal_system_agent, k)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # Like the xAI stub, but it also RECORDS each request's decoded form body so
  # the PKCE parameters can be asserted on the wire.
  defp stub(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.request_path, URI.decode_query(raw)})

      {status, response} =
        Agent.get_and_update(agent, fn state ->
          case Map.get(state, conn.request_path, {404, %{}}) do
            [head | rest] when rest != [] -> {head, Map.put(state, conn.request_path, rest)}
            [head] -> {head, state}
            single -> {single, state}
          end
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(response))
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
    :ok
  end

  defp jwt(claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{payload}.signature"
  end

  defp silent, do: fn _line -> :ok end

  defp device_code_response do
    {200,
     %{
       "device_code" => "dc-secret",
       "user_code" => "QWEN-9999",
       "verification_uri" => "https://chat.qwen.ai/device",
       "expires_in" => 600,
       "interval" => 0
     }}
  end

  defp connect!(entry), do: :ok = SubscriptionStore.put("qwen", entry)

  defp live_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "device_code",
        "access_token" => "at-live",
        "refresh_token" => "rt-live",
        "expires_at" => System.system_time(:second) + 3600,
        "base_url" => @portal
      },
      overrides
    )
  end

  describe "connect" do
    test "binds the grant with PKCE: challenge on the authorization leg, matching verifier on the exchange" do
      stub(%{
        "/api/v1/oauth2/device/code" => device_code_response(),
        "/api/v1/oauth2/token" => {200,
         %{
           "access_token" => "at-1",
           "refresh_token" => "rt-1",
           "expires_in" => 3600,
           "resource_url" => "portal.qwen.ai",
           "id_token" => jwt(%{"email" => "qwen@example.com"})
         }}
      })

      assert {:ok, entry} = Qwen.login(io: silent())

      assert_received {:request, "/api/v1/oauth2/device/code", auth_params}
      assert_received {:request, "/api/v1/oauth2/token", token_params}

      # The challenge is sent, declared S256, and is NOT the verifier itself
      # (which is what `plain` would be, and is the failure mode PKCE exists
      # to prevent).
      challenge = auth_params["code_challenge"]
      verifier = token_params["code_verifier"]

      assert auth_params["code_challenge_method"] == "S256"
      assert is_binary(challenge) and challenge != ""
      assert is_binary(verifier) and verifier != ""
      refute challenge == verifier

      # And they are a genuine pair — one grant, one binding.
      assert PKCE.verify(verifier, challenge)

      assert token_params["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
      assert token_params["client_id"] == "f0304373b74a44d2b584a3fb70ca9e56"
      assert auth_params["scope"] == "openid profile email model.completion"

      assert entry["access_token"] == "at-1"
      assert entry["account_id"] == "qwen@example.com"
      # Derived from the provider's own `resource_url`, pinned at consent.
      assert entry["base_url"] == @portal

      status = Subscription.status("qwen")
      assert status.connected?
      assert status.verified?
      assert status.account == "qwen@example.com"
    end

    test "a fresh verifier is generated per sign-in attempt" do
      stub(%{
        "/api/v1/oauth2/device/code" => device_code_response(),
        "/api/v1/oauth2/token" => {200, %{"access_token" => "at", "expires_in" => 3600}}
      })

      assert {:ok, _} = Qwen.login(io: silent())
      assert_received {:request, "/api/v1/oauth2/device/code", first}
      assert_received {:request, "/api/v1/oauth2/token", _}

      assert {:ok, _} = Qwen.login(io: silent())
      assert_received {:request, "/api/v1/oauth2/device/code", second}

      refute first["code_challenge"] == second["code_challenge"]
    end

    test "a denied sign-in leaves NOTHING behind" do
      stub(%{
        "/api/v1/oauth2/device/code" => device_code_response(),
        "/api/v1/oauth2/token" => {400, %{"error" => "access_denied"}}
      })

      assert {:error, :access_denied} = Qwen.login(io: silent())
      refute SubscriptionStore.connected?("qwen")
    end
  end

  describe "the per-account endpoint" do
    test "resolve_base_url/1 follows the provider's own normalisation rules" do
      # Bare host — what Qwen actually returns.
      assert Qwen.resolve_base_url("portal.qwen.ai") == @portal
      # Already schemed, and/or already suffixed: no doubling.
      assert Qwen.resolve_base_url("https://portal.qwen.ai") == @portal
      assert Qwen.resolve_base_url("https://portal.qwen.ai/v1") == @portal
      assert Qwen.resolve_base_url("https://portal.qwen.ai/v1/") == @portal
      assert Qwen.resolve_base_url("  portal.qwen.ai  ") == @portal
      # A different region gets a different endpoint, which is the point.
      assert Qwen.resolve_base_url("other.qwen.ai") == "https://other.qwen.ai/v1"
    end

    test "an absent, blank or non-string resource_url falls back to DashScope" do
      assert Qwen.resolve_base_url(nil) == @dashscope
      assert Qwen.resolve_base_url("") == @dashscope
      assert Qwen.resolve_base_url("   ") == @dashscope
      assert Qwen.resolve_base_url(%{"host" => "evil.example"}) == @dashscope
      assert Qwen.resolve_base_url(42) == @dashscope
    end

    test "sign-in with no resource_url pins the DashScope endpoint rather than guessing" do
      stub(%{
        "/api/v1/oauth2/device/code" => device_code_response(),
        "/api/v1/oauth2/token" => {200, %{"access_token" => "at", "expires_in" => 3600}}
      })

      assert {:ok, entry} = Qwen.login(io: silent())
      assert entry["base_url"] == @dashscope
    end
  end

  describe "disconnect" do
    test "logout removes the marker, and a STATUS READ does not put it back" do
      connect!(live_entry())
      assert :ok = Subscription.logout("qwen")

      refute Subscription.status("qwen").connected?
      refute Qwen.connected?()
      assert Qwen.pinned_base_url() == @dashscope

      assert SubscriptionStore.fetch("qwen") == nil
    end

    test "logout is idempotent on a provider that was never connected" do
      assert :ok = Subscription.logout("qwen")
      refute SubscriptionStore.connected?("qwen")
    end
  end

  describe "token refresh" do
    test "renews inside the skew and adopts a rotated refresh token" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))

      stub(%{
        "/api/v1/oauth2/token" =>
          {200, %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 3600}}
      })

      assert {:ok, "at-2"} = Subscription.access_token("qwen")

      stored = SubscriptionStore.fetch("qwen")
      assert stored["access_token"] == "at-2"
      assert stored["refresh_token"] == "rt-2"
    end

    test "a refresh carries NO code_verifier — there is no authorization code to bind" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))
      stub(%{"/api/v1/oauth2/token" => {200, %{"access_token" => "at-2", "expires_in" => 3600}}})

      assert {:ok, "at-2"} = Subscription.access_token("qwen")

      assert_received {:request, "/api/v1/oauth2/token", params}
      assert params["grant_type"] == "refresh_token"
      refute Map.has_key?(params, "code_verifier")
      refute Map.has_key?(params, "code_challenge")
    end

    test "a refresh that omits resource_url KEEPS the pinned endpoint" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))
      stub(%{"/api/v1/oauth2/token" => {200, %{"access_token" => "at-2", "expires_in" => 3600}}})

      assert {:ok, "at-2"} = Subscription.access_token("qwen")
      # Not silently demoted to the DashScope default, which would move a
      # working account onto the API-key endpoint.
      assert SubscriptionStore.fetch("qwen")["base_url"] == @portal
    end

    test "a refresh that MOVES the account is honoured" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))

      stub(%{
        "/api/v1/oauth2/token" =>
          {200,
           %{"access_token" => "at-2", "expires_in" => 3600, "resource_url" => "eu.qwen.ai"}}
      })

      assert {:ok, "at-2"} = Subscription.access_token("qwen")
      assert SubscriptionStore.fetch("qwen")["base_url"] == "https://eu.qwen.ai/v1"
    end

    test "a live token is returned with no network call, and a revoked grant is terminal" do
      connect!(live_entry())
      assert {:ok, "at-live"} = Subscription.access_token("qwen")

      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))
      stub(%{"/api/v1/oauth2/token" => {400, %{"error" => "invalid_grant"}}})
      assert {:error, :refresh_token_invalid} = Subscription.access_token("qwen")
    end

    test "status is a PURE READ — it reports expiry without refreshing" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) - 1}))

      status = Subscription.status("qwen")
      assert status.connected?
      assert status.expired?
      assert SubscriptionStore.fetch("qwen")["access_token"] == "at-live"
    end
  end

  describe "the API-key path is unchanged" do
    test "a configured key is used verbatim, at DashScope, honouring the URL override" do
      Application.put_env(:optimal_system_agent, :qwen_api_key, "qwen-key-1")

      assert {:ok, "qwen-key-1", @dashscope} = OpenAICompatProvider.resolved_credential(:qwen)

      Application.put_env(:optimal_system_agent, :qwen_url, "https://proxy.example/v1")

      assert {:ok, "qwen-key-1", "https://proxy.example/v1"} =
               OpenAICompatProvider.resolved_credential(:qwen)
    end

    test "the key WINS over a connected account, and the account code never runs" do
      Application.put_env(:optimal_system_agent, :qwen_api_key, "qwen-key-1")
      connect!(live_entry(%{"expires_at" => System.system_time(:second) - 1, "refresh_token" => ""}))

      assert {:ok, "qwen-key-1", @dashscope} = OpenAICompatProvider.resolved_credential(:qwen)
    end

    test "with no key and no account, the result is the same nil-key state as before" do
      assert {:ok, nil, @dashscope} = OpenAICompatProvider.resolved_credential(:qwen)
    end
  end

  describe "the account path" do
    test "carries the account bearer token, against the endpoint pinned at sign-in" do
      connect!(live_entry())

      assert {:ok, "at-live", @portal} = OpenAICompatProvider.resolved_credential(:qwen)
    end

    test "IGNORES a Qwen base-URL override — a subscription token is never redirected" do
      Application.put_env(:optimal_system_agent, :qwen_url, "https://evil.example/v1")
      connect!(live_entry())

      assert {:ok, "at-live", @portal} = OpenAICompatProvider.resolved_credential(:qwen)
    end

    test "a failed refresh becomes an actionable message with NO token in it" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))
      stub(%{"/api/v1/oauth2/token" => {400, %{"error" => "invalid_grant"}}})

      assert {:error, message} = OpenAICompatProvider.resolved_credential(:qwen)
      assert message =~ "Qwen"
      refute message =~ "at-live"
      refute message =~ "rt-live"
    end
  end

  describe "the catalog row" do
    test "is ONE row with two modes, and the key half is untouched" do
      row = Enum.find(Onboarding.providers_list(), &(&1.id == "qwen"))

      assert row.auth_modes == [:api_key, :oauth]
      assert row.env_var == "QWEN_API_KEY"
      assert row.base_url == @dashscope
      assert row.requires_key == true
      assert row.key_optional == true
      assert row.tab == "accounts"
      assert row.subscription.kind == :device_code
      # The two modes genuinely do not share a host, so the shown value is the
      # key endpoint and the account endpoint is resolved at sign-in.
      assert row.subscription.base_url == @dashscope

      assert Enum.count(Onboarding.providers_list(), &(&1.id == "qwen")) == 1
    end

    test "the capability is live end to end, not merely declared" do
      assert Subscription.supported?("qwen")
      assert Subscription.available?("qwen")
      assert Subscription.impl("qwen") == Qwen
      assert Onboarding.usable_auth_modes("qwen") == [:api_key, :oauth]
      assert Onboarding.dual_mode?("qwen")
      assert Onboarding.interactive_sign_in?("qwen")

      assert [%{value: :oauth}, %{value: :api_key}] = Onboarding.auth_options("qwen")
    end
  end
end
