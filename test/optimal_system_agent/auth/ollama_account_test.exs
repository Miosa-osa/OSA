defmodule OptimalSystemAgent.Auth.OllamaAccountTest do
  @moduledoc """
  Ollama Cloud's second auth mode: "use my signed-in local Ollama daemon".

  Three properties are asserted here that the other subscription providers do
  not have to worry about, and each one is a bug this subsystem has already
  produced at least once:

  1. **The API-key mode is unchanged.** Account mode is a second door on an
     existing provider, not a new provider, so the regression risk is that
     adding it perturbs the key path everyone already uses.
  2. **The connection check is free and local.** `/api/me` on loopback is
     unauthenticated and costs nothing; a status surface that started spending
     a metered request — or dialling a remote host — would have broken the
     contract `status/0` is written against.
  3. **Signing out sticks.** A status surface must never re-create a marker the
     user just removed. That has now appeared twice elsewhere in this
     subsystem, once over HTTP.

  Every test runs against a **stub daemon** on loopback, so the suite is
  hermetic and does not depend on whether the machine running it happens to
  have Ollama installed or signed in.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.OllamaAccount, as: Auth
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Onboarding

  @signed_in ~s({"id":"abc","email":"user@example.com","name":"box","plan":"max"})

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-ollama-acct-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_home = System.get_env("OSA_HOME")
    prev_host = System.get_env("OLLAMA_HOST")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      if prev_host, do: System.put_env("OLLAMA_HOST", prev_host), else: System.delete_env("OLLAMA_HOST")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # ── A stub Ollama daemon on loopback ────────────────────────────────────
  #
  # Every request it receives is forwarded to the test process, which is what
  # makes "nothing was dialled" and "nothing was authenticated" assertable
  # rather than merely believed.

  defp daemon(status, body) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    test = self()

    spawn(fn -> serve(lsock, status, body, test) end)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    port
  end

  defp serve(lsock, status, body, test) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        req =
          case :gen_tcp.recv(sock, 0, 2_000) do
            {:ok, data} -> data
            _ -> ""
          end

        send(test, {:daemon_request, req})

        :gen_tcp.send(sock, [
          "HTTP/1.1 #{status} X\r\n",
          "Content-Type: application/json\r\n",
          "Content-Length: #{byte_size(body)}\r\n",
          "Connection: close\r\n\r\n",
          body
        ])

        :gen_tcp.close(sock)
        serve(lsock, status, body, test)

      _ ->
        :ok
    end
  end

  # A port nothing is listening on: bind, learn the number, release it.
  defp dead_port do
    {:ok, s} = :gen_tcp.listen(0, [ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  defp point_at(port), do: System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")

  defp requests do
    receive do
      {:daemon_request, r} -> [r | requests()]
    after
      0 -> []
    end
  end

  describe "account mode with a signed-in daemon" do
    test "connects, and records the account without recording a credential" do
      point_at(daemon(200, @signed_in))

      assert {:ok, entry} = Auth.login(io: fn _ -> :ok end)
      assert entry["kind"] == "local_daemon"
      assert entry["account_id"] == "user@example.com"
      assert entry["plan_type"] == "max"

      stored = SubscriptionStore.fetch("ollama_cloud")

      # The credential-shape invariant. OSA stores NO Ollama token: the daemon
      # owns the machine's Ed25519 key and signs its own cloud requests. A
      # regression that started holding one here would have quietly turned a
      # proxy into a credential store.
      for forbidden <- ~w(access_token refresh_token id_token client_id token code_verifier api_key) do
        refute Map.has_key?(stored, forbidden),
               "the Ollama account mode must never store #{forbidden} — the daemon owns the credential"
      end
    end

    test "status reports the account, and no expiry it cannot know" do
      point_at(daemon(200, @signed_in))

      assert %{connected?: false} = Auth.status()
      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)

      status = Auth.status()
      assert status.connected?
      assert status.verified?
      assert status.account == "user@example.com"
      assert status.plan == "max"
      assert status.expires_at == nil
      refute status.expired?
    end

    test "there is no token to hand out, and asking says so rather than returning nil" do
      assert {:error, :externally_managed} = Auth.access_token()
    end

    test "it is reachable through the shared Subscription facade" do
      assert "ollama_cloud" in Subscription.supported()
      assert Subscription.impl("ollama_cloud") == Auth
      assert Subscription.available?("ollama_cloud")
    end
  end

  describe "the connection check costs nothing" do
    test "the probe is one unauthenticated loopback POST to /api/me" do
      point_at(daemon(200, @signed_in))

      assert {:ok, _} = Auth.probe()

      assert [req] = requests()
      assert req =~ "POST /api/me"
      # No credential is sent, because none is needed and none exists. If this
      # ever grows an Authorization header, the "free" claim is gone.
      refute String.downcase(req) =~ "authorization:"
    end

    test "status/0 is a pure read — it does not talk to the daemon at all" do
      point_at(daemon(200, @signed_in))

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      # Drain the login's probe.
      assert requests() != []

      _ = Auth.status()
      _ = Subscription.status_all()

      assert requests() == [],
             "drawing a status screen must not dial the daemon, let alone spend anything"
    end
  end

  describe "failure paths name the command that fixes them" do
    test "no daemon running" do
      point_at(dead_port())

      assert {:error, :ollama_daemon_unreachable} = Auth.probe()

      msg = capture(fn io -> Auth.login(io: io) end)
      assert msg =~ "ollama serve"
      assert Subscription.message(:ollama_daemon_unreachable, "Ollama Cloud") =~ "ollama serve"
    end

    test "daemon running but signed out" do
      point_at(daemon(401, ~s({"error":"not signed in"})))

      assert {:error, :ollama_not_signed_in} = Auth.probe()

      msg = capture(fn io -> Auth.login(io: io) end)
      assert msg =~ "ollama signin"

      # A signed-out daemon is not a credential problem OSA can solve, so the
      # message must not pretend re-running something in OSA will fix it.
      assert Subscription.message(:ollama_not_signed_in, "Ollama Cloud") =~ "ollama signin"
    end

    test "a 200 that names no account is treated as signed out, not as connected" do
      point_at(daemon(200, ~s({"id":"abc"})))

      assert {:error, :ollama_not_signed_in} = Auth.probe()
      assert is_nil(SubscriptionStore.fetch("ollama_cloud"))
    end

    test "a remote OLLAMA_HOST is declined, not dialled" do
      # https at a loopback address: reachable, but not a plaintext loopback
      # daemon, so it must be refused. The listener proves the refusal is a
      # decision and not a failed connection — nothing ever arrives.
      port = daemon(200, @signed_in)
      System.put_env("OLLAMA_HOST", "https://127.0.0.1:#{port}")

      assert {:error, {:ollama_host_remote, _}} = Auth.probe()
      assert requests() == [], "a remote OLLAMA_HOST must not be contacted at all"

      System.put_env("OLLAMA_HOST", "http://ollama.example.com:11434")
      assert {:error, {:ollama_host_remote, url}} = Auth.probe()
      assert url =~ "ollama.example.com"
      assert Subscription.message({:ollama_host_remote, url}, "Ollama Cloud") =~ "OLLAMA_HOST"
    end
  end

  describe "signing out" do
    test "forgets OSA's marker only, and says so" do
      point_at(daemon(200, @signed_in))

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      assert :ok = Auth.logout()
      assert %{connected?: false} = Auth.status()
      assert is_nil(SubscriptionStore.fetch("ollama_cloud"))
    end

    test "a still-signed-in daemon does not re-seed the marker" do
      point_at(daemon(200, @signed_in))

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      assert :ok = Auth.logout()

      assert {:error, :not_connected} = Auth.live_status()
      assert is_nil(SubscriptionStore.fetch("ollama_cloud"))
    end

    test "a status-surface health check never resurrects a marker the user removed" do
      point_at(daemon(200, @signed_in))

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      assert :ok = Auth.logout()

      # This is the shape reachable over `POST /onboarding/health-check`: the
      # caller asks about account mode, but is NOT a setup surface. It must
      # report "not connected" and leave the store alone.
      assert {:error, %{error: "not_connected"}} =
               Onboarding.health_check(%{"provider" => "ollama_cloud", "auth_mode" => "oauth"})

      assert is_nil(SubscriptionStore.fetch("ollama_cloud")),
             "a status surface re-creating the marker is what makes sign-out appear to do nothing"
    end

    test "the setup verify step MAY create it — that is the difference" do
      point_at(daemon(200, @signed_in))

      assert {:ok, %{auth_mode: "subscription", plan: "max"}} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "auth_mode" => "oauth",
                 "during_setup" => true
               })

      assert SubscriptionStore.fetch("ollama_cloud")["account_id"] == "user@example.com"
    end
  end

  describe "the API-key mode is untouched" do
    test "the catalog entry keeps its key affordance and gains the account option" do
      entry = Enum.find(Onboarding.providers_list(), &(&1.id == "ollama_cloud"))

      assert entry.env_var == "OLLAMA_API_KEY"
      assert entry.base_url == "https://ollama.com"
      assert entry.requires_key == true
      assert entry.key_optional == true

      assert entry.auth_modes == [:api_key, :oauth]
      assert Onboarding.dual_mode?("ollama_cloud")

      # The account mode's endpoint is the local daemon, and it is declared
      # separately precisely because it is NOT the entry's base_url.
      assert entry.subscription.base_url =~ "127.0.0.1"
    end

    test "both routes are offered, sign-in first, described by who pays" do
      assert [oauth, api_key] = Onboarding.auth_options("ollama_cloud")
      assert oauth.value == :oauth
      assert api_key.value == :api_key
      assert api_key.hint =~ ~r/pay-per-token/i
    end

    test "a health check WITH a key still verifies against ollama.com, ignoring the daemon" do
      point_at(daemon(200, @signed_in))
      # Even with account mode connected, an explicitly-typed key wins: an
      # explicit credential is never shadowed by an auto-discovered one.
      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)

      plug = fn conn ->
        send(self(), :keyed_request)
        Req.Test.json(conn, %{"message" => %{"content" => "ok"}})
      end

      assert {:ok, result} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "api_key" => "sk-real-key",
                 "req_plug" => plug
               })

      refute Map.get(result, :auth_mode) == "subscription",
             "a pasted key must take the keyed path, not be silently replaced by the account"
    end

    test "the model list with a key is the shipped catalog, exactly as before" do
      point_at(daemon(200, @signed_in))

      assert {:ok, keyed} = Onboarding.model_list("ollama_cloud", api_key: "sk-real-key")
      assert {:ok, plain} = Onboarding.model_list("ollama_cloud", [])

      assert keyed == plain
      assert Enum.any?(keyed, &(&1.id == "glm-5.2:cloud"))

      # And the daemon was never asked, because the key mode does not use it.
      assert requests() == []
    end
  end

  describe "the model list in account mode is learned, not invented" do
    test "it is what the daemon says this account can reach" do
      body = ~s({"models":[
        {"name":"glm-5.2:cloud","remote_host":"https://ollama.com:443","details":{"context_length":1000000},"capabilities":["completion","tools"]},
        {"name":"some-new-model:cloud","remote_host":"https://ollama.com:443","details":{"context_length":4096},"capabilities":["completion"]},
        {"name":"llama3.2:3b","details":{"context_length":131072},"capabilities":["completion"]}
      ]})

      port = daemon(200, body)

      assert {:ok, models} =
               Onboarding.model_list("ollama_cloud", base_url: "http://127.0.0.1:#{port}")

      ids = Enum.map(models, & &1.id)

      # Hosted tags only — a purely local model is not an Ollama Cloud offering.
      assert "glm-5.2:cloud" in ids
      refute "llama3.2:3b" in ids

      # A model the shipped catalog has never heard of is still offered, because
      # the daemon is the authority on what the account can reach.
      assert "some-new-model:cloud" in ids

      # And a catalog model this account CANNOT reach is not offered.
      refute "kimi-k3:cloud" in ids
    end

    test "a signed-in daemon offering nothing shows nothing, rather than the full catalog" do
      port = daemon(200, ~s({"models":[]}))

      assert {:ok, []} = Onboarding.model_list("ollama_cloud", base_url: "http://127.0.0.1:#{port}")
    end

    test "an unreachable daemon falls back to the catalog — not knowing is not the same as empty" do
      port = dead_port()

      assert {:ok, models} =
               Onboarding.model_list("ollama_cloud", base_url: "http://127.0.0.1:#{port}")

      assert Enum.any?(models, &(&1.id == "glm-5.2:cloud"))
    end
  end

  defp capture(fun) do
    parent = self()
    fun.(fn line -> send(parent, {:io, line}) end)
    drain_io()
  end

  defp drain_io do
    receive do
      {:io, line} -> to_string(line) <> "\n" <> drain_io()
    after
      0 -> ""
    end
  end
end
