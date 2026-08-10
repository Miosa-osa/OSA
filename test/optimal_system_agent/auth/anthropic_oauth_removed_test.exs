defmodule OptimalSystemAgent.Auth.AnthropicOAuthRemovedTest do
  @moduledoc """
  The Anthropic subscription sign-in is GONE, and must stay gone.

  OSA used to ship an OAuth 2.0 + PKCE flow against `console.anthropic.com`
  driven by **Claude Code's first-party client id**, sending the subscription
  fingerprint `Authorization: Bearer …` + `anthropic-beta: oauth-2025-04-20`.
  It was removed because it made the *user* breach their own Anthropic Consumer
  Terms, Anthropic blocks it server-side, and the endpoint it targeted now 404s.

  These tests are the guard rails:

    * nothing anywhere reintroduces the client id, the beta header, or a
      `Bearer` variant on the Anthropic provider;
    * the **API-key path is untouched** — that is the supported path and the
      27-provider onboarding depends on it;
    * every former entry point says "no longer available" rather than 500ing,
      404ing or silently doing nothing;
    * a stale credential on disk is deleted on upgrade, and the user is told.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias OptimalSystemAgent.Auth.LegacyAnthropicOAuth
  alias OptimalSystemAgent.Channels.HTTP
  alias OptimalSystemAgent.Providers.Anthropic

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @sub_beta "oauth-2025-04-20"

  @http_opts HTTP.init([])

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_oauth_removed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", tmp)
    LegacyAnthropicOAuth.reset_purged_flag()

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      LegacyAnthropicOAuth.reset_purged_flag()
      File.rm_rf(tmp)
    end)

    {:ok, osa_home: tmp}
  end

  # ── The flow itself is gone from the tree ────────────────────────────────

  describe "the removed flow leaves nothing behind" do
    test "the OAuth client module no longer exists" do
      refute Code.ensure_loaded?(OptimalSystemAgent.Auth.OAuth),
             "OptimalSystemAgent.Auth.OAuth was the Anthropic subscription OAuth client " <>
               "and must not exist"

      refute File.exists?("lib/optimal_system_agent/auth/oauth.ex")
    end

    test "Claude Code's client id and the subscription beta appear nowhere in lib/" do
      hits =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          body = File.read!(file)

          cond do
            String.contains?(body, @client_id) -> [{file, "client id"}]
            # The legacy-removal module names the beta only inside its own
            # explanatory moduledoc; a header value would be a quoted literal.
            String.contains?(body, ~s("#{@sub_beta}")) -> [{file, "beta header value"}]
            true -> []
          end
        end)

      assert hits == [],
             "the Anthropic subscription OAuth fingerprint is still present: #{inspect(hits)}"
    end
  end

  # ── API-KEY AUTH IS UNTOUCHED (the supported path) ───────────────────────

  describe "Anthropic API-key auth still builds a correct request" do
    test "x-api-key is sent, with no Bearer and no subscription beta" do
      headers = Anthropic.build_headers({:api_key, "sk-ant-api03-TESTKEY"}, false)

      assert {"x-api-key", "sk-ant-api03-TESTKEY"} in headers
      assert {"content-type", "application/json"} in headers
      assert Enum.any?(headers, fn {k, _} -> k == "anthropic-version" end)

      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      refute Enum.any?(headers, fn {_, v} -> is_binary(v) and String.contains?(v, "Bearer") end)
      refute Enum.any?(headers, fn {_, v} -> is_binary(v) and String.contains?(v, @sub_beta) end)
    end

    test "a bare string key is still accepted (the pre-existing 2-arity shape)" do
      headers = Anthropic.build_headers("sk-ant-api03-BARE", false)
      assert {"x-api-key", "sk-ant-api03-BARE"} in headers
    end

    test "thinking and 1M betas still ride along on the API-key path" do
      headers = Anthropic.build_headers({:api_key, "sk-ant-x"}, true, "claude-sonnet-4-6")
      betas = for {"anthropic-beta", v} <- headers, do: v

      assert length(betas) == 1
      assert hd(betas) =~ "interleaved-thinking-2025-05-14"
      refute hd(betas) =~ @sub_beta
    end
  end

  describe "the duplicate anthropic-beta bug is fixed" do
    test "at most ONE anthropic-beta header is ever emitted, in every combination" do
      # The old `{:oauth, token}` clause emitted its own `anthropic-beta`
      # entry, so whenever any other beta was active the request carried TWO
      # `anthropic-beta` headers. Betas are now collected in exactly one place.
      for thinking <- [true, false],
          model <- [nil, "claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-3-5"],
          auth <- [{:api_key, "sk-ant-x"}, "sk-ant-x"] do
        headers = Anthropic.build_headers(auth, thinking, model)
        count = Enum.count(headers, fn {k, _} -> k == "anthropic-beta" end)

        assert count <= 1,
               "duplicate anthropic-beta for thinking=#{thinking} model=#{inspect(model)}: " <>
                 inspect(headers)
      end
    end
  end

  describe "resolve_auth never returns an :oauth credential" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :anthropic_api_key)
      Application.delete_env(:optimal_system_agent, :anthropic_api_key)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :anthropic_api_key, prev),
          else: Application.delete_env(:optimal_system_agent, :anthropic_api_key)
      end)

      :ok
    end

    test "a configured API key resolves to an {:api_key, _} tuple, never an OAuth one" do
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-configured")

      # The CredentialPool (or a .env key on the dev box) may legitimately
      # outrank the app-env key, so assert on the SHAPE — what matters is that
      # `:oauth` is no longer a value `resolve_auth/0` can produce.
      assert {:api_key, key} = Anthropic.resolve_auth()
      assert is_binary(key) and key != ""
    end

    test "no key yields an actionable error, never an OAuth fallback" do
      case Anthropic.resolve_auth() do
        {:api_key, key} ->
          # A developer machine may legitimately have ANTHROPIC_API_KEY set.
          assert is_binary(key)

        {:error, reason} ->
          assert reason =~ "not configured"
          assert reason =~ "ANTHROPIC_API_KEY"
          # Classifies as missing_api_key so the user gets `osa setup` guidance.
          assert OptimalSystemAgent.Providers.ErrorCatalog.classify(reason) == :missing_api_key
      end
    end
  end

  # ── Entry points say "no longer available" ───────────────────────────────

  describe "the four :9089 OAuth routes are explicitly gone, not broken" do
    for {method, path} <- [
          {:get, "/onboarding/oauth/start"},
          {:get, "/onboarding/oauth/status"},
          {:delete, "/onboarding/oauth/status"}
        ] do
      test "#{method} #{path} returns 410 with an actionable JSON message" do
        conn = conn(unquote(method), unquote(path)) |> HTTP.call(@http_opts)

        assert conn.status == 410
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "anthropic_oauth_removed"
        assert body["connected"] == false
        assert body["message"] =~ "no longer"
        assert body["message"] =~ "API key"
      end
    end

    test "GET /onboarding/oauth/callback returns a 410 HTML page, not a token exchange" do
      conn = conn(:get, "/onboarding/oauth/callback?code=x&state=y") |> HTTP.call(@http_opts)

      assert conn.status == 410
      assert conn.resp_body =~ "no longer available"
      refute conn.resp_body =~ "Connected"
    end
  end

  # These two commands used to print a fixed apology for the removed Anthropic
  # OAuth flow. That was correct for exactly one release: as soon as the first
  # subscription provider shipped, "/logout" was telling users "no account
  # sign-in sessions exist" while three of them were live in the catalog, and
  # `Subscription.logout/1` had no callers anywhere. They now drive the real
  # `CLI.Auth` surface. What must NOT come back is any suggestion that OSA can
  # sign a user in to Anthropic.
  describe "REPL /login and /logout drive the real sign-in surface" do
    test "/login anthropic says it has no account sign-in, and never offers to open a browser" do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.Commands.cmd_login("anthropic", "sess")
        end)

      assert out =~ "does not support account sign-in"
      refute out =~ "Opening your browser"
      refute out =~ "console.anthropic.com/oauth"

      # The remaining Anthropic route is an API key, and the providers that DO
      # support sign-in are named rather than left to be guessed at.
      assert out =~ "claude_cli"
    end

    test "/logout anthropic reports honestly that there was nothing to clear" do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.Commands.cmd_logout("anthropic", "sess")
        end)

      assert out =~ "was not connected"

      refute out =~ "API keys only",
             "the old blanket claim that OSA has no account sign-ins is now false"
    end

    test "/logout with no argument lists what is connected instead of guessing one" do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.Commands.cmd_logout("", "sess")
        end)

      assert out =~ "Account sign-ins"
      assert out =~ "/logout <provider>"
    end
  end

  # ── Stale credentials are DELETED on upgrade, and the user is told ───────

  describe "stale ~/.osa/oauth.json is purged" do
    test "purge/0 deletes the file and records why", %{osa_home: home} do
      path = Path.join(home, "oauth.json")
      File.write!(path, ~s({"access_token":"stale","refresh_token":"also-stale"}))

      assert LegacyAnthropicOAuth.credentials_present?()
      assert LegacyAnthropicOAuth.purge() == :purged
      refute File.exists?(path)
      assert LegacyAnthropicOAuth.purged?()
    end

    test "purge/0 is a no-op (and never raises) when there is nothing to purge" do
      assert LegacyAnthropicOAuth.purge() == :absent
      refute LegacyAnthropicOAuth.purged?()
    end

    test "the notice names the reason AND the replacement" do
      notice = LegacyAnthropicOAuth.notice()
      assert notice =~ "Anthropic sign-in"
      assert notice =~ "no longer"
      assert notice =~ "ANTHROPIC_API_KEY"
      assert notice =~ "osa setup"
    end

    test "a previously-signed-in user's next Anthropic call explains the removal", %{
      osa_home: home
    } do
      File.write!(Path.join(home, "oauth.json"), ~s({"access_token":"stale"}))
      assert LegacyAnthropicOAuth.purge() == :purged

      prev = Application.get_env(:optimal_system_agent, :anthropic_api_key)
      Application.delete_env(:optimal_system_agent, :anthropic_api_key)
      prev_env = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if prev, do: Application.put_env(:optimal_system_agent, :anthropic_api_key, prev)
        if prev_env, do: System.put_env("ANTHROPIC_API_KEY", prev_env)
      end)

      case Anthropic.resolve_auth() do
        {:error, reason} ->
          assert reason =~ "Anthropic sign-in"
          assert reason =~ "API key"

        # A pooled/`.env` key on the developer's box wins — still never OAuth.
        {:api_key, key} ->
          assert is_binary(key)
      end
    end

    test "doctor surfaces the removal without declaring the system NOT READY", %{osa_home: home} do
      File.write!(Path.join(home, "oauth.json"), ~s({"access_token":"stale"}))

      rows = OptimalSystemAgent.CLI.Doctor.checks()
      row = Enum.find(rows, fn {_s, name, _d} -> name == "Anthropic sign-in" end)

      assert {status, "Anthropic sign-in", detail} = row
      assert status == :optional, "must not fail the health check for a user who has an API key"
      assert detail =~ "no longer"
      refute File.exists?(Path.join(home, "oauth.json")), "doctor purges too (cold-VM path)"
    end
  end
end
