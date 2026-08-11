defmodule OptimalSystemAgent.Auth.Providers.OpenAICodexTest do
  @moduledoc """
  ChatGPT plan sign-in.

  OpenAI's device flow is not RFC 8628, and its polling endpoint returns
  **403/404 for most of the sign-in's duration** to mean "the user has not
  finished yet". Treating those as failures breaks the flow completely while
  looking like a permissions bug, so that behaviour is pinned first.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.OpenAICodex
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)
    Application.put_env(:optimal_system_agent, :codex_issuer, "https://stub.invalid")

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      for k <- [:codex_issuer, :auth_req_options] do
        Application.delete_env(:optimal_system_agent, k)
      end

      File.rm_rf(dir)
    end)

    :ok
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

  # A real-shaped Codex access token: the account id and plan are read from
  # the JWT payload, so the tests must exercise actual decoding.
  defp jwt(claims) do
    payload =
      %{"https://api.openai.com/auth" => claims}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "header.#{payload}.signature"
  end

  @usercode %{"user_code" => "WXYZ-1234", "device_auth_id" => "dev-auth-1", "interval" => 0}

  defp collector do
    parent = self()
    fn line -> send(parent, {:line, line}) end
  end

  defp printed, do: collect([]) |> Enum.reverse() |> Enum.join("\n")

  defp collect(acc) do
    receive do
      {:line, l} -> collect([l | acc])
    after
      0 -> acc
    end
  end

  describe "the happy path" do
    test "signs in, extracts plan and account from the token, and persists" do
      token = jwt(%{"chatgpt_account_id" => "acct_42", "chatgpt_plan_type" => "pro"})

      stub(%{
        "/api/accounts/deviceauth/usercode" => {200, @usercode},
        "/api/accounts/deviceauth/token" =>
          {200, %{"authorization_code" => "authcode", "code_verifier" => "verifier"}},
        "/oauth/token" =>
          {200, %{"access_token" => token, "refresh_token" => "rt-1", "expires_in" => 3600}}
      })

      assert {:ok, entry} = OpenAICodex.login(io: collector(), open_browser: false)

      output = printed()
      assert output =~ "WXYZ-1234"
      assert output =~ "third-party", "the user must be told what they are connecting"
      assert output =~ "pro plan"

      assert entry["account_id"] == "acct_42"
      assert entry["plan_type"] == "pro"
      assert entry["refresh_token"] == "rt-1"

      # Pinned at sign-in so a later `*_URL` override cannot redirect a
      # subscription bearer token to another host.
      assert entry["base_url"] == "https://chatgpt.com/backend-api/codex"
    end

    test "403 and 404 while polling mean 'not yet', not failure" do
      token = jwt(%{"chatgpt_account_id" => "a"})

      stub(%{
        "/api/accounts/deviceauth/usercode" => {200, @usercode},
        "/api/accounts/deviceauth/token" => [
          {403, %{}},
          {404, %{}},
          {200, %{"authorization_code" => "c", "code_verifier" => "v"}}
        ],
        "/oauth/token" => {200, %{"access_token" => token, "expires_in" => 3600}}
      })

      assert {:ok, _} = OpenAICodex.login(io: collector(), open_browser: false)
    end

    test "the credential lands at 0600 and status reports it without network access" do
      token = jwt(%{"chatgpt_plan_type" => "plus"})

      stub(%{
        "/api/accounts/deviceauth/usercode" => {200, @usercode},
        "/api/accounts/deviceauth/token" =>
          {200, %{"authorization_code" => "c", "code_verifier" => "v"}},
        "/oauth/token" => {200, %{"access_token" => token, "expires_in" => 3600}}
      })

      {:ok, _} = OpenAICodex.login(io: collector(), open_browser: false)

      {:ok, stat} = File.stat(SubscriptionStore.path())
      assert Bitwise.band(stat.mode, 0o777) == 0o600

      Application.put_env(:optimal_system_agent, :auth_req_options,
        plug: fn _ -> raise "status/0 must not make a network call" end
      )

      assert %{connected?: true, plan: "plus"} = OpenAICodex.status()
    end
  end

  describe "JWT claim extraction" do
    test "reads the OpenAI auth claims" do
      claims = OpenAICodex.jwt_claims(jwt(%{"chatgpt_plan_type" => "pro"}))
      assert claims["chatgpt_plan_type"] == "pro"
    end

    test "a malformed token yields no claims instead of raising" do
      # These claims are cosmetic plus one header. A broken token must never
      # take down a sign-in that otherwise worked.
      assert OpenAICodex.jwt_claims("not-a-jwt") == %{}
      assert OpenAICodex.jwt_claims(nil) == %{}
      assert OpenAICodex.jwt_claims("a.!!!.c") == %{}
    end
  end

  describe "refresh" do
    test "rotates the refresh token and re-reads the plan" do
      SubscriptionStore.put("openai_codex", %{
        "access_token" => "old",
        "refresh_token" => "rt-old",
        "expires_at" => System.system_time(:second) + 10
      })

      new_token = jwt(%{"chatgpt_account_id" => "acct_9", "chatgpt_plan_type" => "pro"})

      stub(%{
        "/oauth/token" =>
          {200, %{"access_token" => new_token, "refresh_token" => "rt-new", "expires_in" => 3600}}
      })

      assert {:ok, ^new_token} = OpenAICodex.access_token()

      stored = SubscriptionStore.fetch("openai_codex")
      assert stored["refresh_token"] == "rt-new"
      assert stored["account_id"] == "acct_9"
    end

    # Deliberately TWO strikes, not one. Deleting the credential is
    # irreversible from the user's side — they must run the whole sign-in
    # again — and providers do return `invalid_grant` for transient reasons.
    # One bad minute signing someone out mid-conversation is a worse outcome
    # than one extra failed turn, so the first rejection is survived and the
    # second is believed.
    test "a revoked grant signs out locally, but only after a second consecutive rejection" do
      OpenAICodex.reset_refresh_failures()

      SubscriptionStore.put("openai_codex", %{
        "access_token" => "old",
        "refresh_token" => "rt",
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{"/oauth/token" => {400, %{"error" => "invalid_grant"}}})

      assert {:error, :refresh_token_invalid} = OpenAICodex.access_token()

      assert OpenAICodex.status().connected?,
             "one invalid_grant may be transient; the credential is kept"

      assert {:error, :refresh_token_invalid} = OpenAICodex.access_token()

      refute OpenAICodex.status().connected?,
             "twice in a row is a revoked grant, not a blip"
    end

    test "a success between two rejections resets the strike count" do
      OpenAICodex.reset_refresh_failures()

      SubscriptionStore.put("openai_codex", %{
        "access_token" => "old",
        "refresh_token" => "rt",
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{"/oauth/token" => {400, %{"error" => "invalid_grant"}}})
      assert {:error, :refresh_token_invalid} = OpenAICodex.access_token()

      stub(%{
        "/oauth/token" =>
          {200, %{"access_token" => "fresh", "refresh_token" => "rt2", "expires_in" => 3600}}
      })

      assert {:ok, "fresh"} = OpenAICodex.access_token()

      # Back to a clean slate: the next single failure must not sign the user
      # out on what would otherwise be strike two.
      SubscriptionStore.put("openai_codex", %{
        "access_token" => "fresh",
        "refresh_token" => "rt2",
        "expires_at" => System.system_time(:second) + 10
      })

      stub(%{"/oauth/token" => {400, %{"error" => "invalid_grant"}}})
      assert {:error, :refresh_token_invalid} = OpenAICodex.access_token()
      assert OpenAICodex.status().connected?
    end

    # The reactive path: a token that looks fine to the clock but is rejected
    # by the server. Proactive refresh alone can never catch this — clock
    # skew, server-side revocation, and a credential with no `expires_at` at
    # all all produce it — and before this it surfaced as the dead-end string
    # "HTTP 401: ..." with nothing behind it.
    test "force_refresh/1 renews a token the server rejected even though it had not expired" do
      OpenAICodex.reset_refresh_failures()

      SubscriptionStore.put("openai_codex", %{
        "access_token" => "rejected",
        "refresh_token" => "rt",
        # An hour of validity left by the clock's reckoning.
        "expires_at" => System.system_time(:second) + 3600
      })

      refute OpenAICodex.needs_refresh?(SubscriptionStore.fetch("openai_codex")),
             "the proactive path has no reason to act here, which is the whole problem"

      stub(%{
        "/oauth/token" =>
          {200, %{"access_token" => "renewed", "refresh_token" => "rt2", "expires_in" => 3600}}
      })

      assert {:ok, "renewed"} = OpenAICodex.force_refresh("rejected")
      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "renewed"
    end

    test "force_refresh/1 adopts a peer's rotated token instead of spending the refresh token again" do
      OpenAICodex.reset_refresh_failures()

      # The state after another OSA process has already refreshed: the token
      # on disk is no longer the one that got the 401.
      SubscriptionStore.put("openai_codex", %{
        "access_token" => "already-rotated-by-a-peer",
        "refresh_token" => "rt2",
        "expires_at" => System.system_time(:second) + 3600
      })

      # Any network call at all would be a double-spend of a single-use
      # rotating refresh token, which invalidates the whole grant.
      stub(%{"/oauth/token" => {500, %{"error" => "must_not_be_called"}}})

      assert {:ok, "already-rotated-by-a-peer"} = OpenAICodex.force_refresh("rejected")
    end

    test "credential/0 returns token, account and base URL as one consistent value" do
      SubscriptionStore.put("openai_codex", %{
        "access_token" => "tok",
        "account_id" => "acct_1",
        "base_url" => "https://chatgpt.com/backend-api/codex",
        "expires_at" => System.system_time(:second) + 86_400
      })

      assert {:ok, cred} = OpenAICodex.credential()
      assert cred.access_token == "tok"
      assert cred.account_id == "acct_1"
      assert cred.base_url == "https://chatgpt.com/backend-api/codex"
    end
  end

  describe "failure modes" do
    test "login rate limiting is reported as throttling, never as a credential problem" do
      # The user may not even have a credential yet. Telling them to
      # re-authenticate would be nonsense.
      stub(%{"/api/accounts/deviceauth/usercode" => {429, %{}}})

      assert {:error, :login_rate_limited} =
               OpenAICodex.login(io: collector(), open_browser: false)

      message = Subscription.message(:login_rate_limited, "ChatGPT")
      refute message =~ ~r/re-?auth|sign in again/i
      assert message =~ "rate-limiting"
    end

    test "a cancelled sign-in stops cleanly" do
      stub(%{
        "/api/accounts/deviceauth/usercode" => {200, @usercode},
        "/api/accounts/deviceauth/token" => {403, %{}}
      })

      assert {:error, :cancelled} =
               OpenAICodex.login(io: collector(), open_browser: false, on_tick: fn -> :cancel end)

      refute OpenAICodex.status().connected?
    end

    test "an incomplete device response is reported rather than half-persisted" do
      stub(%{"/api/accounts/deviceauth/usercode" => {200, %{"user_code" => "X"}}})

      assert {:error, :device_code_incomplete} =
               OpenAICodex.login(io: collector(), open_browser: false)

      refute OpenAICodex.status().connected?
    end

    test "signing out is idempotent" do
      SubscriptionStore.put("openai_codex", %{"access_token" => "t"})
      assert :ok = OpenAICodex.logout()
      refute OpenAICodex.status().connected?
      assert :ok = OpenAICodex.logout()
    end
  end

  describe "originator honesty" do
    test "OSA identifies itself rather than claiming to be OpenAI's Codex CLI" do
      # Borrowing a client id because no registration path exists is one thing;
      # actively asserting a false identity on every request is another. If
      # this ever needs to change it must be a deliberate operator override,
      # not a default.
      assert OpenAICodex.originator() == "osa"
      refute OpenAICodex.originator() == "codex_cli_rs"
    end

    test "a 403 from the edge gate is explained, not mistaken for a bad credential" do
      message = Subscription.message(:originator_rejected, "ChatGPT")

      assert message =~ "honestly"
      assert message =~ "OSA_CODEX_ORIGINATOR"
      assert message =~ ~r/sign-in is valid/i
    end
  end

  describe "the provider module" do
    test "refuses to call out when no plan is connected, with an actionable message" do
      assert {:error, message} = OptimalSystemAgent.Providers.OpenAICodex.chat([])
      assert message =~ "Not signed in"
    end

    test "surfaces plan quota headers, distinguishing 'unknown' from 'exhausted'" do
      # A plan's failure mode is a hard window wait, not a bill — so the UI
      # must be able to show remaining quota. Reporting an unknown quota as
      # zero would be worse than reporting nothing.
      headers = %{
        "x-codex-primary-used-percent" => ["73.5"],
        "x-codex-primary-window-minutes" => ["300"],
        "x-codex-limit-name" => ["primary"]
      }

      info = OptimalSystemAgent.Providers.OpenAICodex.rate_limit_info(headers)
      assert info.used_percent == 73.5
      assert info.window_minutes == 300
      assert info.limit_name == "primary"

      assert OptimalSystemAgent.Providers.OpenAICodex.rate_limit_info(%{}) == nil
    end

    test "the Codex model catalogue is separate from plain OpenAI's" do
      codex = OptimalSystemAgent.Providers.OpenAICodex.available_models()
      openai = OptimalSystemAgent.Providers.OpenAIModels.ids()

      # Pin the default rather than an arbitrary member: a catalogue that no
      # longer contains what `default_model/0` returns hands a freshly
      # signed-in user a model their plan does not offer, which is exactly the
      # failure this list aged into once before.
      assert OptimalSystemAgent.Providers.OpenAICodex.default_model() in codex
      assert Enum.all?(codex, &(&1 not in openai)) or codex != openai
    end
  end
end
