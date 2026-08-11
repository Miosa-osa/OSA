defmodule OptimalSystemAgent.Auth.Providers.MiniMaxTest do
  @moduledoc """
  MiniMax account sign-in.

  This provider is DORMANT — implemented and tested, registered nowhere. The
  first test in this file pins that fact, because "dormant" is a decision that
  can be undone by accident: adding it to the catalog without a transport is
  precisely the failure the rule against it exists to prevent.

  Everything else here covers the two things that are genuinely different
  about MiniMax's flow and are silent when wrong: the `expired_in` field that
  is sometimes a TTL and sometimes an absolute millisecond instant, and a
  `status` field on a 200 response standing in for RFC 8628's error codes.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.PKCE
  alias OptimalSystemAgent.Auth.Providers.MiniMax
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Onboarding

  @global_inference "https://api.minimax.io/anthropic"
  @cn_inference "https://api.minimaxi.com/anthropic"

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-minimax-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      Application.delete_env(:optimal_system_agent, :auth_req_options)
      File.rm_rf(dir)
    end)

    :ok
  end

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

  defp silent, do: fn _line -> :ok end

  # `/oauth/code` must echo the `state` we sent, so the stub has to read it
  # off the request rather than return a fixed value.
  defp code_plug(extra) do
    parent = self()

    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(raw)
      send(parent, {:request, conn.request_path, params})

      body =
        Map.merge(
          %{
            "user_code" => "MM-4242",
            "verification_uri" => "https://minimax.io/device",
            "expired_in" => 600,
            "interval" => 0,
            "state" => params["state"]
          },
          extra
        )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp stub_login(token_script, code_extra \\ %{}) do
    code = code_plug(code_extra)
    {:ok, agent} = Agent.start_link(fn -> token_script end)
    parent = self()

    plug = fn conn ->
      case conn.request_path do
        "/oauth/code" ->
          code.(conn)

        "/oauth/token" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:request, "/oauth/token", URI.decode_query(raw)})

          {status, response} =
            Agent.get_and_update(agent, fn
              [head | rest] when rest != [] -> {head, rest}
              [head] -> {head, [head]}
              single -> {single, single}
            end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(status, Jason.encode!(response))
      end
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
    :ok
  end

  defp success_tokens(extra \\ %{}) do
    Map.merge(
      %{
        "status" => "success",
        "access_token" => "mm-at-1",
        "refresh_token" => "mm-rt-1",
        "expired_in" => 3600
      },
      extra
    )
  end

  defp connect!(entry), do: :ok = SubscriptionStore.put("minimax", entry)

  defp live_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "pkce_user_code",
        "access_token" => "mm-at-live",
        "refresh_token" => "mm-rt-live",
        "expires_at" => System.system_time(:second) + 3600,
        "region" => "global",
        "portal_base_url" => "https://api.minimax.io",
        "base_url" => @global_inference
      },
      overrides
    )
  end

  describe "it is dormant, and that is the point" do
    test "is registered in NO catalog, NO dispatch map and NO transport" do
      # A provider you can select but never send a request through is worse
      # than one that is absent. Until a MiniMax (Anthropic Messages)
      # transport exists, none of these may know about it.
      refute Subscription.supported?("minimax")
      refute Subscription.available?("minimax")
      assert Subscription.impl("minimax") == nil
      refute "minimax" in Subscription.supported()

      refute Enum.any?(Onboarding.providers_list(), &(&1.id == "minimax"))
      assert Onboarding.auth_modes("minimax") == [:api_key]
      assert Onboarding.subscription_kind("minimax") == nil
    end

    test "generic dispatch degrades to a clear message rather than crashing" do
      assert {:error, :unsupported_provider} = Subscription.login("minimax")
      assert {:error, :unsupported_provider} = Subscription.access_token("minimax")
      refute Subscription.status("minimax").connected?
    end

    test "the module itself is nonetheless complete and callable" do
      # `function_exported?/3` answers false for a module that simply has not
      # been LOADED yet, and a dormant module is exactly the kind nothing else
      # in a full suite run has referenced. Forcing the load first is the
      # difference between testing the module's shape and testing the code
      # server's lazy-loading schedule.
      assert Code.ensure_loaded?(MiniMax)

      for fun <- [:login, :status, :access_token, :logout, :connected?, :pinned_base_url] do
        assert function_exported?(MiniMax, fun, 0) or function_exported?(MiniMax, fun, 1),
               "MiniMax.#{fun} is missing"
      end
    end
  end

  describe "connect" do
    test "binds the grant with PKCE and pins BOTH hosts for the chosen region" do
      stub_login({200, success_tokens()})

      assert {:ok, entry} = MiniMax.login(io: silent())

      assert_received {:request, "/oauth/code", auth_params}
      assert_received {:request, "/oauth/token", token_params}

      assert auth_params["code_challenge_method"] == "S256"
      assert auth_params["scope"] == "group_id profile model.completion"
      assert auth_params["client_id"] == "78257093-7e40-4613-99e0-527b14b39113"

      assert token_params["grant_type"] == "urn:ietf:params:oauth:grant-type:user_code"
      assert token_params["user_code"] == "MM-4242"

      # A genuine pair, not `plain` PKCE.
      refute auth_params["code_challenge"] == token_params["code_verifier"]
      assert PKCE.verify(token_params["code_verifier"], auth_params["code_challenge"])

      assert entry["access_token"] == "mm-at-1"
      assert entry["region"] == "global"
      assert entry["portal_base_url"] == "https://api.minimax.io"
      # The Anthropic Messages endpoint — NOT an OpenAI chat path.
      assert entry["base_url"] == @global_inference
      assert MiniMax.pinned_base_url() == @global_inference
    end

    test "the state parameter is high-entropy and a mismatched echo aborts the flow" do
      stub_login({200, success_tokens()})
      assert {:ok, _} = MiniMax.login(io: silent())
      assert_received {:request, "/oauth/code", params}

      {:ok, raw} = Base.url_decode64(params["state"], padding: false)
      assert byte_size(raw) >= 32

      # Now an endpoint that echoes the WRONG state: possible CSRF, so stop.
      SubscriptionStore.delete("minimax")
      stub_login({200, success_tokens()}, %{"state" => "not-the-state-we-sent"})

      assert {:error, :state_mismatch} = MiniMax.login(io: silent())
      refute SubscriptionStore.connected?("minimax")
    end

    test "'pending' on a 200 means keep waiting, not fail" do
      stub_login([{200, %{"status" => "pending"}}, {200, success_tokens()}])

      assert {:ok, entry} = MiniMax.login(io: silent())
      assert entry["access_token"] == "mm-at-1"
    end

    test "'error' on a 200 is a refusal, and surfaces MiniMax's own message with no secrets" do
      stub_login({200, %{"status" => "error", "base_resp" => %{"status_msg" => "user declined"}}})

      assert {:error, {:oauth_error, "user declined"}} = MiniMax.login(io: silent())
      refute SubscriptionStore.connected?("minimax")
    end

    test "the CN region is a different account, with a different pair of hosts" do
      stub_login({200, success_tokens()})

      assert {:ok, entry} = MiniMax.login(io: silent(), region: "cn")
      assert entry["region"] == "cn"
      assert entry["portal_base_url"] == "https://api.minimaxi.com"
      assert entry["base_url"] == @cn_inference
    end

    test "an unknown region is refused rather than silently defaulted to global" do
      assert {:error, {:unknown_region, "atlantis"}} =
               MiniMax.login(io: silent(), region: "atlantis")

      refute SubscriptionStore.connected?("minimax")

      assert MiniMax.region_hosts("atlantis") == nil
      assert MiniMax.regions() == ["cn", "global"]
      assert MiniMax.default_region() == "global"
    end
  end

  describe "expired_in is overloaded, and reading it backwards is catastrophic" do
    setup do
      %{now: 1_800_000_000}
    end

    test "a small value is a TTL in seconds", %{now: now} do
      assert MiniMax.expires_at(3600, now) == now + 3600
      assert MiniMax.expires_at("3600", now) == now + 3600
      # The largest plausible TTL is still unambiguous.
      assert MiniMax.expires_at(10_000_000, now) == now + 10_000_000
    end

    test "a large value is an ABSOLUTE unix-millisecond instant", %{now: now} do
      ms = (now + 3600) * 1000
      assert MiniMax.expires_at(ms, now) == now + 3600

      # The regression this guards: read as a TTL, this would put expiry
      # ~57,000 years out and the token would never be refreshed.
      refute MiniMax.expires_at(ms, now) > now + 100_000
    end

    test "absent, zero, negative and non-numeric values yield nil, not a bogus expiry", %{
      now: now
    } do
      for bad <- [nil, 0, -1, "", "soon", %{}] do
        assert MiniMax.expires_at(bad, now) == nil
      end
    end

    test "a sign-in whose grant reports absolute-ms expiry stores a sane expiry" do
      now = System.system_time(:second)
      stub_login({200, success_tokens(%{"expired_in" => (now + 3600) * 1000})})

      assert {:ok, entry} = MiniMax.login(io: silent())
      assert_in_delta entry["expires_at"], now + 3600, 5
      refute MiniMax.expired?(entry)
    end
  end

  describe "disconnect" do
    test "logout removes the marker, and a STATUS READ does not put it back" do
      connect!(live_entry())
      assert :ok = MiniMax.logout()

      refute MiniMax.status().connected?
      refute MiniMax.connected?()
      assert MiniMax.pinned_base_url() == nil
      assert SubscriptionStore.fetch("minimax") == nil
    end

    test "logout is idempotent on a provider that was never connected" do
      assert :ok = MiniMax.logout()
      refute MiniMax.connected?()
    end
  end

  describe "token refresh" do
    test "renews inside the skew, adopts a rotated refresh token, and sends no verifier" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 10}))

      stub(%{
        "/oauth/token" =>
          {200,
           %{
             "status" => "success",
             "access_token" => "mm-at-2",
             "refresh_token" => "mm-rt-2",
             "expired_in" => 3600
           }}
      })

      assert {:ok, "mm-at-2"} = MiniMax.access_token()

      assert_received {:request, "/oauth/token", params}
      assert params["grant_type"] == "refresh_token"
      refute Map.has_key?(params, "code_verifier")

      stored = SubscriptionStore.fetch("minimax")
      assert stored["access_token"] == "mm-at-2"
      assert stored["refresh_token"] == "mm-rt-2"
    end

    test "a provider that does NOT rotate keeps the existing refresh token" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 10}))

      stub(%{
        "/oauth/token" =>
          {200, %{"status" => "success", "access_token" => "mm-at-3", "expired_in" => 3600}}
      })

      assert {:ok, "mm-at-3"} = MiniMax.access_token()
      assert SubscriptionStore.fetch("minimax")["refresh_token"] == "mm-rt-live"
    end

    test "the refresh goes to the PORTAL pinned at sign-in, not the inference host" do
      connect!(
        live_entry(%{
          "expires_at" => System.system_time(:second) + 10,
          "region" => "cn",
          "portal_base_url" => "https://api.minimaxi.com",
          "base_url" => @cn_inference
        })
      )

      {:ok, agent} = Agent.start_link(fn -> [] end)

      plug = fn conn ->
        Agent.update(agent, &[conn.host <> conn.request_path | &1])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"status" => "success", "access_token" => "x", "expired_in" => 3600})
        )
      end

      Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)

      assert {:ok, "x"} = MiniMax.access_token()
      assert Agent.get(agent, & &1) == ["api.minimaxi.com/oauth/token"]
    end

    test "a live token is returned with no network call at all" do
      connect!(live_entry())
      # No stub: any HTTP attempt would fail.
      assert {:ok, "mm-at-live"} = MiniMax.access_token()
    end

    test "a failed refresh is terminal and leaks nothing" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) + 10}))

      stub(%{
        "/oauth/token" =>
          {200, %{"status" => "error", "base_resp" => %{"status_msg" => "invalid_grant"}}}
      })

      assert {:error, {:oauth_error, msg}} = MiniMax.access_token()
      assert msg == "invalid_grant"
      refute msg =~ "mm-rt-live"
      refute msg =~ "mm-at-live"
    end

    test "an unconnected provider asks for sign-in rather than reporting a broken credential" do
      assert {:error, :not_connected} = MiniMax.access_token()
    end

    test "status is a PURE READ — it reports expiry without refreshing" do
      connect!(live_entry(%{"expires_at" => System.system_time(:second) - 1}))

      status = MiniMax.status()
      assert status.connected?
      assert status.expired?
      assert SubscriptionStore.fetch("minimax")["access_token"] == "mm-at-live"
    end
  end
end
