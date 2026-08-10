defmodule OptimalSystemAgent.Auth.Providers.CopilotTest do
  @moduledoc """
  End-to-end sign-in for the first provider implementing the
  `Auth.Subscription` behaviour: connect, persist, recognise on the next run,
  refresh, sign out, and fail honestly.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.Copilot
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-copilot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    prev_id = Application.get_env(:optimal_system_agent, :copilot_client_id)
    Application.put_env(:optimal_system_agent, :copilot_client_id, "Iv1.test-client-id")

    Application.put_env(:optimal_system_agent, :github_device_code_url, "https://stub.invalid/device/code")
    Application.put_env(:optimal_system_agent, :github_token_url, "https://stub.invalid/oauth/token")
    Application.put_env(:optimal_system_agent, :github_user_url, "https://stub.invalid/user")

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_id,
        do: Application.put_env(:optimal_system_agent, :copilot_client_id, prev_id),
        else: Application.delete_env(:optimal_system_agent, :copilot_client_id)

      for k <- [:github_device_code_url, :github_token_url, :github_user_url, :auth_req_options] do
        Application.delete_env(:optimal_system_agent, k)
      end

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

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

  @authorization %{
    "device_code" => "dev-code",
    "user_code" => "ABCD-1234",
    "verification_uri" => "https://stub.invalid/activate",
    "expires_in" => 900,
    "interval" => 0
  }

  # Capture what the user is shown, so the flow's UX is asserted rather than
  # assumed.
  defp collector do
    parent = self()
    fn line -> send(parent, {:line, line}) end
  end

  defp printed, do: collect([]) |> Enum.reverse() |> Enum.join("\n")

  defp collect(acc) do
    receive do
      {:line, line} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  describe "the happy path" do
    test "signs in, shows the code, and persists the credential" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" =>
          {200, %{"access_token" => "gho_secret", "refresh_token" => "ghr_secret", "expires_in" => 28_800}},
        "/user" => {200, %{"login" => "octocat"}}
      })

      assert {:ok, entry} = Copilot.login(io: collector(), open_browser: false)

      output = printed()
      assert output =~ "ABCD-1234", "the user must be shown the code they have to type"
      assert output =~ "https://stub.invalid/activate"
      assert output =~ "third-party", "the user must be told they are connecting an account to a third-party tool"
      assert output =~ "octocat"

      assert entry["access_token"] == "gho_secret"
      assert entry["account"] == "octocat"

      # The endpoint is pinned AT SIGN-IN, so a later `*_URL` override from an
      # untrusted workspace cannot redirect a subscription bearer token to an
      # attacker-controlled host.
      assert entry["base_url"] == "https://api.githubcopilot.com"
    end

    test "the credential lands on disk at 0600" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"access_token" => "gho_secret"}},
        "/user" => {200, %{"login" => "octocat"}}
      })

      {:ok, _} = Copilot.login(io: collector(), open_browser: false)

      {:ok, stat} = File.stat(SubscriptionStore.path())
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "the second run recognises the connection and shows which mode is active" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"access_token" => "gho_secret", "expires_in" => 28_800}},
        "/user" => {200, %{"login" => "octocat"}}
      })

      {:ok, _} = Copilot.login(io: collector(), open_browser: false)

      status = Copilot.status()
      assert status.connected?
      assert status.account == "octocat"
      refute status.expired?

      # And the provider picker badges it, so a user who signed in last week
      # does not come back to a blank row and assume nothing is wired up.
      detected = OptimalSystemAgent.Onboarding.detect_existing().detected
      copilot = Enum.find(detected, &(&1.provider == "copilot"))
      assert copilot
      assert copilot.source == "subscription"
      assert copilot.key_preview =~ "octocat"
    end

    test "sign-in still succeeds when the account lookup fails" do
      # Identifying the account is cosmetic. Failing a sign-in that actually
      # worked because a label could not be fetched would be absurd.
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"access_token" => "gho_secret"}},
        "/user" => {500, %{}}
      })

      assert {:ok, entry} = Copilot.login(io: collector(), open_browser: false)
      assert entry["access_token"] == "gho_secret"
      assert Copilot.status().connected?
    end
  end

  describe "signing out" do
    test "forgets the credential and is idempotent" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"access_token" => "gho_secret"}},
        "/user" => {200, %{"login" => "octocat"}}
      })

      {:ok, _} = Copilot.login(io: collector(), open_browser: false)
      assert Copilot.status().connected?

      assert :ok = Copilot.logout()
      refute Copilot.status().connected?
      assert :ok = Copilot.logout()
    end
  end

  describe "refresh" do
    test "refreshes proactively before expiry and rotates the refresh token" do
      # GitHub rotates the refresh token on every use. Keeping the old one
      # would spend an already-consumed token next time and invalidate the
      # whole grant.
      SubscriptionStore.put("copilot", %{
        "access_token" => "old",
        "refresh_token" => "ghr_old",
        # Inside the refresh skew window.
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{
        "/oauth/token" => {200, %{"access_token" => "new", "refresh_token" => "ghr_new", "expires_in" => 28_800}}
      })

      assert {:ok, "new"} = Copilot.access_token()
      assert SubscriptionStore.fetch("copilot")["refresh_token"] == "ghr_new"
    end

    test "a still-valid token is returned without any network call" do
      SubscriptionStore.put("copilot", %{
        "access_token" => "still-good",
        "refresh_token" => "ghr",
        "expires_at" => System.system_time(:second) + 86_400
      })

      # No stub installed: if this dialled out it would fail.
      Application.delete_env(:optimal_system_agent, :auth_req_options)
      assert {:ok, "still-good"} = Copilot.access_token()
    end

    test "a non-expiring token is never treated as needing refresh" do
      # An OAuth App issues a token with no expiry and NO refresh token.
      # Trying to refresh it would fail every request for a credential that is
      # perfectly fine.
      SubscriptionStore.put("copilot", %{"access_token" => "forever", "expires_at" => nil})

      refute Copilot.needs_refresh?(SubscriptionStore.fetch("copilot"))
      refute Copilot.expired?(SubscriptionStore.fetch("copilot"))
      assert {:ok, "forever"} = Copilot.access_token()
    end

    test "a revoked grant signs out locally so it is not retried on every message" do
      SubscriptionStore.put("copilot", %{
        "access_token" => "old",
        "refresh_token" => "ghr_revoked",
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{"/oauth/token" => {400, %{"error" => "invalid_grant"}}})

      assert {:error, :refresh_token_invalid} = Copilot.access_token()
      refute Copilot.status().connected?
    end

    test "a transient refresh failure keeps the credential" do
      SubscriptionStore.put("copilot", %{
        "access_token" => "old",
        "refresh_token" => "ghr",
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{"/oauth/token" => {503, %{"error" => "server_error"}}})

      assert {:error, _} = Copilot.access_token()
      assert Copilot.status().connected?, "a flaky network must not destroy a working sign-in"
    end

    test "status/1 never performs network I/O" do
      # osa doctor / osa auth status / the model picker all call this. None of
      # them should be able to trigger a refresh — let alone a refresh failure
      # — as a side effect of drawing a screen.
      SubscriptionStore.put("copilot", %{
        "access_token" => "old",
        "refresh_token" => "ghr",
        "expires_at" => System.system_time(:second) - 1
      })

      Application.put_env(:optimal_system_agent, :auth_req_options,
        plug: fn _ -> raise "status/0 must not make a network call" end
      )

      assert %{connected?: true, expired?: true} = Copilot.status()
    end
  end

  describe "failure modes produce messages, not crashes" do
    test "a cancelled sign-in" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "authorization_pending"}}
      })

      assert {:error, :cancelled} =
               Copilot.login(io: collector(), open_browser: false, on_tick: fn -> :cancel end)

      refute Copilot.status().connected?
      assert Subscription.message(:cancelled, "GitHub Copilot") =~ "API key"
    end

    test "a denied approval" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "access_denied"}}
      })

      assert {:error, :access_denied} = Copilot.login(io: collector(), open_browser: false)
      assert Subscription.message(:access_denied, "GitHub Copilot") =~ "denied"
    end

    test "an expired code" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "expired_token"}}
      })

      assert {:error, :device_code_expired} = Copilot.login(io: collector(), open_browser: false)
    end

    test "no registered client id: sign-in is unavailable rather than broken" do
      Application.delete_env(:optimal_system_agent, :copilot_client_id)
      prev = System.get_env("OSA_COPILOT_CLIENT_ID")
      System.delete_env("OSA_COPILOT_CLIENT_ID")
      on_exit(fn -> if prev, do: System.put_env("OSA_COPILOT_CLIENT_ID", prev) end)

      refute Copilot.available?()
      assert {:error, :not_configured} = Copilot.login(io: collector())
      assert Subscription.message(:not_configured, "GitHub Copilot") =~ "API key"
    end

    test "every failure message points at the API-key fallback" do
      # The whole point of the two-mode fork is that either path reaches the
      # same configured state, so a user blocked on sign-in is never stuck.
      for reason <- [
            :cancelled,
            :access_denied,
            :device_code_expired,
            :refresh_token_invalid,
            :not_configured,
            :not_connected,
            {:transport_error, "timeout"},
            {:http_error, 500}
          ] do
        message = Subscription.message(reason, "GitHub Copilot")

        assert message =~ ~r/API key|api key/,
               "#{inspect(reason)} does not tell the user they can still use an API key: #{message}"
      end
    end

    test "quota and entitlement errors NEVER suggest re-authenticating" do
      # A user out of quota has a valid credential. Telling them to sign in
      # again sends them round a loop that cannot fix billing, and hides the
      # real cause.
      for reason <- [:subscription_required, :insufficient_credits] do
        message = Subscription.message(reason, "GitHub Copilot")

        refute message =~ ~r/re-?auth|sign in again|reconnect/i,
               "#{inspect(reason)} wrongly suggests a credential fix: #{message}"
      end
    end
  end

  describe "the Subscription dispatcher" do
    test "routes by provider id and reports unsupported providers cleanly" do
      assert Subscription.impl("copilot") == Copilot
      assert Subscription.supported?("copilot")
      refute Subscription.supported?("openai")

      assert {:error, :unsupported_provider} = Subscription.login("openai")
      assert %{connected?: false} = Subscription.status("openai")
    end

    test "does not create atoms from caller-supplied provider ids" do
      # An unbounded atom table is a memory-exhaustion vector.
      before = :erlang.system_info(:atom_count)
      for n <- 1..200, do: Subscription.status("bogus-provider-#{n}")
      assert :erlang.system_info(:atom_count) - before < 50
    end
  end
end
