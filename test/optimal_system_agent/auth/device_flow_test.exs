defmodule OptimalSystemAgent.Auth.DeviceFlowTest do
  @moduledoc """
  Device-flow behaviour, driven against an in-process stub rather than a real
  provider. Covers the states RFC 8628 defines as *not* errors (which are the
  ones a naive implementation gets wrong and thereby breaks the happy path),
  and every failure mode a user can actually hit.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.DeviceFlow

  @config %{
    device_code_url: "https://stub.invalid/device/code",
    token_url: "https://stub.invalid/oauth/token",
    client_id: "test-client",
    scope: "read:user"
  }

  # Route stubbed requests by path, returning a canned JSON response. `script`
  # maps a path to either a single {status, body} or a LIST of them, consumed
  # one per call — which is how the polling sequence
  # (pending, pending, success) is expressed.
  defp stub(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      {status, response} =
        Agent.get_and_update(agent, fn state ->
          key = conn.request_path

          case Map.fetch!(state, key) do
            [head | rest] when rest != [] -> {head, Map.put(state, key, rest)}
            [head] -> {head, state}
            single -> {single, state}
          end
        end)

      send(self(), {:stub_request, conn.request_path, params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(response))
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
    on_exit(fn -> Application.delete_env(:optimal_system_agent, :auth_req_options) end)
    :ok
  end

  @authorization %{
    "device_code" => "dev-secret-code",
    "user_code" => "WXYZ-1234",
    "verification_uri" => "https://stub.invalid/activate",
    "expires_in" => 900,
    # Poll immediately — the tests must not actually wait 5s per tick.
    "interval" => 0
  }

  describe "start/1" do
    test "returns a session carrying the user-facing code and the pending-grant secret" do
      stub(%{"/device/code" => {200, @authorization}})

      assert {:ok, session} = DeviceFlow.start(@config)
      assert session.user_code == "WXYZ-1234"
      assert session.device_code == "dev-secret-code"
      assert session.verification_uri == "https://stub.invalid/activate"
      assert session.expires_at > System.system_time(:second)
    end

    test "sends the client id and scope" do
      stub(%{"/device/code" => {200, @authorization}})
      {:ok, _} = DeviceFlow.start(@config)

      assert_received {:stub_request, "/device/code", params}
      assert params["client_id"] == "test-client"
      assert params["scope"] == "read:user"
    end

    test "the pending-grant secret is redacted from inspect output" do
      # device_code is a bearer credential for the pending sign-in: anyone
      # holding it can complete the flow. It must not reach a log line or a
      # crash report via an incidental inspect/1.
      stub(%{"/device/code" => {200, @authorization}})
      {:ok, session} = DeviceFlow.start(@config)

      refute inspect(session) =~ "dev-secret-code"
      assert inspect(session) =~ "REDACTED"
    end

    test "a rejected client id is reported as such" do
      stub(%{"/device/code" => {401, %{"error" => "invalid_client"}}})
      assert {:error, :invalid_client} = DeviceFlow.start(@config)
    end
  end

  describe "poll/3 — the states that are NOT failures" do
    test "keeps polling through authorization_pending and then succeeds" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => [
          {400, %{"error" => "authorization_pending"}},
          {400, %{"error" => "authorization_pending"}},
          {200, %{"access_token" => "at-1", "refresh_token" => "rt-1", "expires_in" => 28_800}}
        ]
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:ok, body} = DeviceFlow.poll(@config, session)
      assert body["access_token"] == "at-1"
    end

    test "honours slow_down instead of treating it as an error" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => [
          {400, %{"error" => "slow_down", "interval" => 0}},
          {200, %{"access_token" => "at-1"}}
        ]
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:ok, %{"access_token" => "at-1"}} = DeviceFlow.poll(@config, session)
    end

    test "an HTTP 400 carrying a pending body is not a transport failure" do
      # Several providers return the pending state with a non-2xx status.
      # Gating on status rather than on the body breaks the happy path for
      # every one of them.
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => [{400, %{"error" => "authorization_pending"}}, {200, %{"access_token" => "ok"}}]
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:ok, _} = DeviceFlow.poll(@config, session)
    end
  end

  describe "poll/3 — failure modes are honest and distinct" do
    setup do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"access_token" => "unused"}}
      })
    end

    test "a denied approval is reported as denial" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "access_denied"}}
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:error, :access_denied} = DeviceFlow.poll(@config, session)
    end

    test "an expired code is reported as expiry, not as denial" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "expired_token"}}
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:error, :device_code_expired} = DeviceFlow.poll(@config, session)
    end

    test "a cancelled flow stops cleanly rather than crashing" do
      # This is Ctrl-C / closing the browser. It must be a message, not a
      # stack trace.
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {400, %{"error" => "authorization_pending"}}
      })

      {:ok, session} = DeviceFlow.start(@config)
      assert {:error, :cancelled} = DeviceFlow.poll(@config, session, fn -> :cancel end)
    end

    test "a session past its deadline expires instead of polling forever" do
      stub(%{"/device/code" => {200, @authorization}})
      {:ok, session} = DeviceFlow.start(@config)
      expired = %{session | expires_at: System.system_time(:second) - 1}

      assert {:error, :device_code_expired} = DeviceFlow.poll(@config, expired)
    end
  end

  describe "refresh/2" do
    test "exchanges a refresh token for a new access token" do
      stub(%{"/oauth/token" => {200, %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 28_800}}})

      assert {:ok, body} = DeviceFlow.refresh(@config, "rt-1")
      assert body["access_token"] == "at-2"

      assert_received {:stub_request, "/oauth/token", params}
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "rt-1"
    end

    test "a revoked or reused grant is reported as permanently invalid" do
      # This must be distinguishable from a transient failure, because the
      # caller has to STOP retrying it on every message.
      stub(%{"/oauth/token" => {400, %{"error" => "invalid_grant"}}})
      assert {:error, :refresh_token_invalid} = DeviceFlow.refresh(@config, "rt-old")
    end
  end

  describe "error classification" do
    test "entitlement and quota problems are never confused with credential problems" do
      # A user out of quota has a perfectly valid credential. Classifying this
      # as an auth error is what produces the "re-authenticate" advice that
      # sends them round a loop which cannot fix billing.
      assert DeviceFlow.classify("subscription_required") == :subscription_required
      assert DeviceFlow.classify("insufficient_quota") == :insufficient_credits

      refute DeviceFlow.classify("subscription_required") == :refresh_token_invalid
    end

    test "an unknown error keeps the provider's own description" do
      assert {:oauth_error, detail} =
               DeviceFlow.classify("weird_failure", %{"error_description" => "something specific"})

      assert detail =~ "weird_failure"
      assert detail =~ "something specific"
    end
  end

  describe "a dropped packet must not destroy an approved grant" do
    # The worst-feeling failure in the whole flow: the user has already opened
    # the browser, typed the code and approved it, and one blip on the next
    # poll throws all of that away and demands a fresh code. A transport error
    # says nothing about the grant, which is sitting approved on the
    # provider's side waiting to be collected.
    test "transport errors mid-poll are retried, and the sign-in still completes" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        n = Agent.get_and_update(agent, &{&1, &1 + 1})

        cond do
          conn.request_path == "/device/code" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(@authorization))

          # Three consecutive failures — under the bound — then success.
          n <= 3 ->
            raise %Req.TransportError{reason: :closed}

          true ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "tok"}))
        end
      end

      Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :auth_req_options) end)

      {:ok, session} = DeviceFlow.start(@config)

      assert {:ok, %{"access_token" => "tok"}} = DeviceFlow.poll(@config, session),
             "a grant the user already approved must survive a few dropped packets"
    end

    test "a severed network still terminates instead of spinning to the deadline" do
      plug = fn conn ->
        if conn.request_path == "/device/code" do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(@authorization))
        else
          raise %Req.TransportError{reason: :nxdomain}
        end
      end

      Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :auth_req_options) end)

      {:ok, session} = DeviceFlow.start(@config)

      assert {:error, {:transport_error, _}} = DeviceFlow.poll(@config, session)
    end

    test "the retry budget is bounded, not unlimited" do
      assert DeviceFlow.max_consecutive_transport_errors() > 1
      assert DeviceFlow.max_consecutive_transport_errors() < 50
    end
  end

  describe "the wait is bounded by OSA's own clock, not only the server's" do
    # Two independent bugs, one pair of fixes. Trusting the server's
    # `expires_in` alone lets a buggy or hostile value pin the CLI for its
    # whole duration; measuring the deadline on the wall clock lets an NTP
    # step backwards extend the wait silently.
    test "an absurd server-supplied expiry does not pin the CLI for its whole duration" do
      Application.put_env(:optimal_system_agent, :device_flow_max_wait_s, 0)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :device_flow_max_wait_s) end)

      stub(%{
        "/device/code" =>
          {200,
           Map.merge(@authorization, %{
             # Ten years. The grant claims to be valid; OSA's own ceiling is
             # what has to stop this.
             "expires_in" => 315_360_000
           })},
        "/oauth/token" => {200, %{"error" => "authorization_pending"}}
      })

      {:ok, session} = DeviceFlow.start(@config)

      assert {:error, :device_code_timeout} = DeviceFlow.poll(@config, session)
    end

    test "the cancel callback is honoured and reported as cancelled, not as a failure" do
      stub(%{
        "/device/code" => {200, @authorization},
        "/oauth/token" => {200, %{"error" => "authorization_pending"}}
      })

      {:ok, session} = DeviceFlow.start(@config)

      assert {:error, :cancelled} = DeviceFlow.poll(@config, session, fn -> :cancel end)
    end
  end

  describe "user agent" do
    test "identifies OSA honestly" do
      # A tool that has to disguise itself to keep working has its answer about
      # whether it should be doing this at all.
      assert DeviceFlow.user_agent() =~ ~r"^osa/"
    end
  end
end
