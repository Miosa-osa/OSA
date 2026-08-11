defmodule OptimalSystemAgent.Auth.Providers.XAITest do
  @moduledoc """
  xAI account sign-in — the second mode on the EXISTING `xai` row.

  The interesting property of this provider is not the device grant (that is
  `DeviceFlow`'s, and it is tested there). It is that adding a second
  credential to a live provider must not disturb the first one. So the
  assertions that matter most here are the negative ones: with an
  `XAI_API_KEY` present, nothing about the request changes — same key, same
  URL, same env override — and the account code does not run at all, even
  when an account IS connected.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.XAI
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.OpenAICompatProvider

  @pinned "https://api.x.ai/v1"

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-xai-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    prev_key = System.get_env("XAI_API_KEY")
    System.put_env("OSA_HOME", dir)
    System.delete_env("XAI_API_KEY")

    # A stray `.env` in the CWD or in a developer's real `~/.osa` must not be
    # able to hand these tests an API key and quietly flip every assertion
    # about the account path onto the key path.
    Application.put_env(:optimal_system_agent, :live_env_file_fallback, false)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_key,
        do: System.put_env("XAI_API_KEY", prev_key),
        else: System.delete_env("XAI_API_KEY")

      for k <- [:auth_req_options, :xai_api_key, :xai_url, :live_env_file_fallback] do
        Application.delete_env(:optimal_system_agent, k)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # A Req plug that answers each request path from a script. A list value is
  # consumed one entry per call, so a poll can be made to return "pending"
  # before it returns a token.
  defp stub(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    plug = fn conn ->
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

  defp connect!(entry) do
    :ok = SubscriptionStore.put("xai", entry)
  end

  defp live_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "device_code",
        "access_token" => "at-live",
        "refresh_token" => "rt-live",
        "expires_at" => System.system_time(:second) + 3600,
        "base_url" => @pinned
      },
      overrides
    )
  end

  describe "connect" do
    test "runs the device grant, shows the code, and persists a marker pinned to the sign-in host" do
      stub(%{
        "/oauth2/device/code" => {200,
         %{
           "device_code" => "dc-secret",
           "user_code" => "ABCD-1234",
           "verification_uri" => "https://x.ai/device",
           "expires_in" => 600,
           "interval" => 0
         }},
        "/oauth2/token" => {200,
         %{
           "access_token" => "at-1",
           "refresh_token" => "rt-1",
           "expires_in" => 3600,
           "id_token" => jwt(%{"email" => "grok@example.com"})
         }}
      })

      seen = self()

      assert {:ok, entry} =
               XAI.login(
                 io: silent(),
                 on_verification: fn payload -> send(seen, {:verification, payload}) end
               )

      # The code reaches a non-terminal surface BEFORE polling starts, rather
      # than only being printed — that is what makes sign-in work from the TUI
      # and not just from a shell.
      assert_received {:verification,
                       %{user_code: "ABCD-1234", verification_uri: "https://x.ai/device"}}

      assert entry["access_token"] == "at-1"
      assert entry["account_id"] == "grok@example.com"
      # Pinned at sign-in, from the marker — not resolved per request.
      assert entry["base_url"] == @pinned

      stored = SubscriptionStore.fetch("xai")
      assert stored["refresh_token"] == "rt-1"

      status = Subscription.status("xai")
      assert status.connected?
      assert status.verified?
      assert status.account == "grok@example.com"
      refute status.expired?
    end

    test "a sign-in that is never approved leaves NOTHING behind" do
      stub(%{
        "/oauth2/device/code" => {200,
         %{
           "device_code" => "dc",
           "user_code" => "AAAA-1111",
           "verification_uri" => "https://x.ai/device",
           "expires_in" => 600,
           "interval" => 0
         }},
        "/oauth2/token" => {400, %{"error" => "access_denied"}}
      })

      assert {:error, :access_denied} = XAI.login(io: silent())
      refute SubscriptionStore.connected?("xai")
      refute Subscription.status("xai").connected?
    end
  end

  describe "disconnect" do
    test "logout removes the marker, and a subsequent STATUS READ does not put it back" do
      connect!(live_entry())
      assert SubscriptionStore.connected?("xai")

      assert :ok = Subscription.logout("xai")
      refute SubscriptionStore.connected?("xai")

      # The regression this pins: a status read that "helpfully" writes a
      # default entry resurrects a credential the user just deleted. Every
      # read below must leave the file exactly as logout left it.
      refute Subscription.status("xai").connected?
      refute XAI.connected?()
      assert XAI.pinned_base_url() == @pinned
      assert Onboarding.decorate_for_ui(%{id: "xai", auth_modes: [:api_key, :oauth]}).auth.state ==
               "needs_sign_in"

      refute SubscriptionStore.connected?("xai")
      assert SubscriptionStore.fetch("xai") == nil
    end

    test "logout is idempotent on a provider that was never connected" do
      assert :ok = Subscription.logout("xai")
      refute SubscriptionStore.connected?("xai")
    end
  end

  describe "token refresh" do
    test "a token inside the refresh skew is renewed, and a ROTATED refresh token is adopted" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))

      stub(%{
        "/oauth2/token" =>
          {200, %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 3600}}
      })

      assert {:ok, "at-2"} = Subscription.access_token("xai")

      stored = SubscriptionStore.fetch("xai")
      assert stored["access_token"] == "at-2"
      assert stored["refresh_token"] == "rt-2"
      assert stored["expires_at"] > System.system_time(:second) + 3000
    end

    test "a provider that does NOT rotate keeps the existing refresh token instead of nulling it" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))

      stub(%{"/oauth2/token" => {200, %{"access_token" => "at-3", "expires_in" => 3600}}})

      assert {:ok, "at-3"} = Subscription.access_token("xai")
      assert SubscriptionStore.fetch("xai")["refresh_token"] == "rt-live"
    end

    test "a comfortably-live token is returned without any network call at all" do
      connect!(live_entry())

      # No stub installed: any HTTP attempt would fail, so a pass here proves
      # the happy path does not dial out.
      assert {:ok, "at-live"} = Subscription.access_token("xai")
    end

    test "a revoked grant reports a terminal reason and does not loop" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))

      stub(%{"/oauth2/token" => {400, %{"error" => "invalid_grant"}}})

      assert {:error, :refresh_token_invalid} = Subscription.access_token("xai")
    end

    test "status is a PURE READ — it reports expiry without refreshing" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) - 1}))

      # Again no stub: `status/1` must not touch the network even when the
      # stored token is plainly dead.
      status = Subscription.status("xai")
      assert status.connected?
      assert status.expired?
      assert SubscriptionStore.fetch("xai")["access_token"] == "at-live"
    end

    test "an unconnected provider asks for sign-in rather than reporting a broken credential" do
      assert {:error, :not_connected} = Subscription.access_token("xai")
    end
  end

  describe "the API-key path is unchanged" do
    test "a configured key is used verbatim, at the configured URL" do
      Application.put_env(:optimal_system_agent, :xai_api_key, "xai-key-1")

      assert {:ok, "xai-key-1", @pinned} = OpenAICompatProvider.resolved_credential(:xai)
    end

    test "the key path still honours the :xai_url override" do
      Application.put_env(:optimal_system_agent, :xai_api_key, "xai-key-1")
      Application.put_env(:optimal_system_agent, :xai_url, "https://proxy.example/v1")

      assert {:ok, "xai-key-1", "https://proxy.example/v1"} =
               OpenAICompatProvider.resolved_credential(:xai)
    end

    test "the key WINS over a connected account, and the account code never runs" do
      Application.put_env(:optimal_system_agent, :xai_api_key, "xai-key-1")
      Application.put_env(:optimal_system_agent, :xai_url, "https://proxy.example/v1")
      # An entry whose token has expired with no refresh token: if the account
      # branch were consulted at all it would error, so returning the key
      # proves it was not.
      connect!(live_entry(%{"expires_at" => System.system_time(:second) - 1, "refresh_token" => ""}))

      assert {:ok, "xai-key-1", "https://proxy.example/v1"} =
               OpenAICompatProvider.resolved_credential(:xai)
    end

    test "with no key and no account, the result is the same nil-key state as before" do
      assert {:ok, nil, @pinned} = OpenAICompatProvider.resolved_credential(:xai)
    end

    test "providers with no account mode are untouched by the seam" do
      Application.put_env(:optimal_system_agent, :groq_api_key, "groq-key")

      on_exit(fn -> Application.delete_env(:optimal_system_agent, :groq_api_key) end)

      assert {:ok, "groq-key", "https://api.groq.com/openai/v1"} =
               OpenAICompatProvider.resolved_credential(:groq)

      Application.delete_env(:optimal_system_agent, :groq_api_key)
      assert {:ok, nil, "https://api.groq.com/openai/v1"} =
               OpenAICompatProvider.resolved_credential(:groq)
    end
  end

  describe "the account path" do
    test "carries the account bearer token, against the base URL pinned at sign-in" do
      connect!(live_entry())

      assert {:ok, "at-live", @pinned} = OpenAICompatProvider.resolved_credential(:xai)
    end

    test "IGNORES an XAI base-URL override — a subscription token is never redirected" do
      # This is the token-redirection hole. An untrusted workspace `.env` that
      # sets XAI_BASE_URL/`:xai_url` must not be able to point OSA's bearer
      # token at a host of its choosing.
      Application.put_env(:optimal_system_agent, :xai_url, "https://evil.example/v1")
      connect!(live_entry())

      assert {:ok, "at-live", @pinned} = OpenAICompatProvider.resolved_credential(:xai)
    end

    test "uses the host recorded in the marker, not the current constant" do
      connect!(live_entry(%{"base_url" => "https://api.x.ai/v1-at-consent-time"}))

      assert {:ok, "at-live", "https://api.x.ai/v1-at-consent-time"} =
               OpenAICompatProvider.resolved_credential(:xai)
    end

    test "a failed refresh becomes an actionable message with NO token in it" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 30}))
      stub(%{"/oauth2/token" => {400, %{"error" => "invalid_grant"}}})

      assert {:error, message} = OpenAICompatProvider.resolved_credential(:xai)
      assert message =~ "xAI (Grok)"
      refute message =~ "at-live"
      refute message =~ "rt-live"
    end
  end

  describe "the catalog row" do
    defp xai_row, do: Enum.find(Onboarding.providers_list(), &(&1.id == "xai"))

    test "is ONE row with two modes, not a second provider" do
      rows = Enum.filter(Onboarding.providers_list(), &String.starts_with?(&1.id, "xai"))
      assert [%{id: "xai"}] = rows
    end

    test "declares both modes and keeps the same host and env var as the key path" do
      row = xai_row()

      assert row.auth_modes == [:api_key, :oauth]
      assert row.env_var == "XAI_API_KEY"
      assert row.base_url == @pinned
      assert row.subscription.base_url == @pinned
      assert row.subscription.kind == :device_code
      # `requires_key` + `key_optional` together are what make BOTH modes
      # reachable from the TUI's onboarding dialog.
      assert row.requires_key == true
      assert row.key_optional == true
      assert row.tab == "accounts"
    end

    test "the capability is live end to end, not merely declared" do
      assert Subscription.supported?("xai")
      assert Subscription.available?("xai")
      assert Subscription.impl("xai") == XAI
      assert "xai" in Subscription.supported()

      assert Onboarding.auth_modes("xai") == [:api_key, :oauth]
      assert Onboarding.usable_auth_modes("xai") == [:api_key, :oauth]
      assert Onboarding.dual_mode?("xai")
      assert Onboarding.subscription_kind("xai") == :device_code
      assert Onboarding.interactive_sign_in?("xai")

      # Sign-in is offered first, and both options are labelled.
      assert [%{value: :oauth, label: oauth_label}, %{value: :api_key, label: key_label}] =
               Onboarding.auth_options("xai")

      assert oauth_label =~ "xAI"
      assert key_label =~ "API key"
    end

    test "every provider that declares :oauth has a working implementation behind it" do
      for row <- Onboarding.providers_list(), :oauth in row.auth_modes do
        assert Subscription.supported?(row.id),
               "#{row.id} declares :oauth with no Auth.Subscription implementation"

        assert Map.has_key?(row, :subscription),
               "#{row.id} declares :oauth with no subscription block"
      end
    end

    # The overlay's whole safety property is that it can only touch rows it
    # names. Listing the untouched ids by hand would make this test go stale
    # the moment a row is legitimately overlaid (it did, on the first one), so
    # instead the set is derived: every compact row that has NOT been given an
    # account mode must still look exactly like a key-only provider.
    @overlaid ~w(xai qwen)

    test "the overlay touched ONLY the rows it names — every other compact row is key-only" do
      compact =
        Onboarding.providers_list()
        |> Enum.filter(&(&1.group in ["more", "bring_your_own"] and &1.requires_key == true))
        |> Enum.reject(&(&1.id in @overlaid))
        |> Enum.reject(&(&1.id in ~w(custom bedrock ollama_cloud)))

      # Guard against the filter silently matching nothing and the loop below
      # asserting about an empty list.
      assert length(compact) >= 10

      for row <- compact do
        assert row.auth_modes == [:api_key], "#{row.id} unexpectedly gained a sign-in mode"

        refute Map.has_key?(row, :subscription),
               "#{row.id} unexpectedly gained a subscription block"

        refute Map.has_key?(row, :key_optional), "#{row.id} unexpectedly became key-optional"
        assert row.tab == "keys"
      end
    end
  end
end
