defmodule OptimalSystemAgent.Auth.AuthSurfaceTest do
  @moduledoc """
  The user-facing half of subscription auth: signing out, cancelling a
  sign-in, and recovering from a 401.

  Every test here corresponds to something that was shipped broken. For one
  release OSA could sign a user *in* to a paid account and had no supported way
  to sign them out — `Subscription.logout/1` was implemented, tested, and had
  zero callers in `lib/`; `/logout` printed a claim that had become false; and
  two moduledocs cited an `osa auth status` command that did not exist. In the
  same release the device flows accepted a cancel callback nobody passed, and a
  401 from the provider surfaced as the literal string "HTTP 401: …" with no
  refresh behind it.

  These are all "the plumbing was right and nothing was connected to it" bugs,
  which is exactly the class that unit tests of the plumbing cannot catch. So
  these tests assert the *wiring*.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Auth.LoginSession
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-authsurface-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # ── P0-1: there is a way out ────────────────────────────────────────────

  describe "signing out is reachable" do
    test "`osa auth logout <provider>` actually deletes the credential" do
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "tok"})
      assert SubscriptionStore.connected?("openai_codex")

      out = capture_io(fn -> assert CLI.Auth.run(["logout", "openai_codex"]) == :ok end)

      refute SubscriptionStore.connected?("openai_codex"),
             "the whole point: the credential is gone from disk"

      assert out =~ "Signed out"
    end

    test "`osa logout` with one connected provider needs no argument" do
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "tok"})

      capture_io(fn -> assert CLI.Auth.run(["logout"]) == :ok end)

      refute SubscriptionStore.connected?("openai_codex")
    end

    test "`osa logout` refuses to guess when several are connected" do
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("claude_cli", %{"kind" => "external_cli"})

      out = capture_io(fn -> assert {:error, :ambiguous} = CLI.Auth.run(["logout"]) end)

      # Signing a user out of something they did not name costs them a
      # re-authentication they did not ask for.
      assert SubscriptionStore.connected?("openai_codex")
      assert SubscriptionStore.connected?("claude_cli")
      assert out =~ "--all"
    end

    test "`--all` clears everything" do
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("claude_cli", %{"kind" => "external_cli"})

      capture_io(fn -> assert CLI.Auth.run(["logout", "--all"]) == :ok end)

      assert SubscriptionStore.list() == %{}
    end

    test "signing out is idempotent and says so rather than claiming success" do
      out = capture_io(fn -> assert CLI.Auth.run(["logout", "openai_codex"]) == :ok end)
      assert out =~ "was not connected"
    end

    test "signing out of a bring-your-own-CLI provider never claims to have cleared the vendor's session" do
      :ok = SubscriptionStore.put("claude_cli", %{"kind" => "external_cli"})

      out = capture_io(fn -> CLI.Auth.run(["logout", "claude_cli"]) end)

      # OSA never held this credential. Implying otherwise would leave the
      # user believing they had signed out of Claude Code, which they have not.
      assert out =~ "claude auth logout"
      assert out =~ "untouched"
    end

    test "`osa auth status` is a real command, and is a pure read" do
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "tok"})

      before = File.stat!(SubscriptionStore.path())
      out = capture_io(fn -> assert CLI.Auth.run(["status"]) == :ok end)

      assert out =~ "openai_codex"
      assert out =~ "connected"

      # Two moduledocs promise that status surfaces never mutate. Reading must
      # not touch the file, refresh a token, or spend a metered request.
      assert File.stat!(SubscriptionStore.path()).mtime == before.mtime
      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "tok"
    end

    test "with nothing connected, status says so and names the way in" do
      out = capture_io(fn -> CLI.Auth.run([]) end)

      assert out =~ "No provider is connected"
      assert out =~ "osa auth login"
    end

    test "an unknown provider is rejected without touching the store" do
      out = capture_io(fn -> assert {:error, _} = CLI.Auth.run(["login", "not_a_provider"]) end)

      assert out =~ "does not support account sign-in"
      assert SubscriptionStore.list() == %{}
    end
  end

  describe "the status line distinguishes recorded from verified" do
    test "an unverified marker is never rendered as a plain green tick" do
      :ok =
        SubscriptionStore.put("copilot_cli", %{"kind" => "external_cli", "verified" => false})

      out = capture_io(fn -> CLI.Auth.run(["status"]) end)

      # `connected?` (OSA has a record of your choice) and `verified?` (OSA has
      # evidence the sign-in is real) are different questions, and Copilot
      # routinely answers yes to the first and no to the second.
      assert out =~ "unconfirmed"
    end

    test "a verified marker is not hedged" do
      :ok = SubscriptionStore.put("copilot_cli", %{"kind" => "external_cli", "verified" => true})

      out = capture_io(fn -> CLI.Auth.run(["status"]) end)
      refute out =~ "unconfirmed"
    end
  end

  # ── P1-5: cancellation is wired ─────────────────────────────────────────

  describe "a sign-in can be cancelled" do
    test "the callback the flows already accepted is now actually produced" do
      LoginSession.reset("openai_codex")
      tick = LoginSession.on_tick("openai_codex", fn _ -> :ok end)

      assert tick.() == :continue

      LoginSession.request_cancel("openai_codex")

      assert tick.() == :cancel,
             "for one release this returned :continue forever because nothing ever set the flag"
    end

    test "cancellation is scoped to one provider" do
      LoginSession.reset("openai_codex")
      LoginSession.reset("copilot")

      LoginSession.request_cancel("openai_codex")

      assert LoginSession.cancelled?("openai_codex")
      refute LoginSession.cancelled?("copilot")
    end

    test "reset clears a stale flag so the next attempt is not cancelled before it starts" do
      LoginSession.request_cancel("openai_codex")
      assert LoginSession.cancelled?("openai_codex")

      LoginSession.reset("openai_codex")
      refute LoginSession.cancelled?("openai_codex")
    end

    test "the poll emits progress, so a fifteen-minute wait is distinguishable from a hang" do
      LoginSession.reset("openai_codex")
      {:ok, sink} = Agent.start_link(fn -> "" end)

      tick = LoginSession.on_tick("openai_codex", fn t -> Agent.update(sink, &(&1 <> t)) end)
      Enum.each(1..13, fn _ -> tick.() end)

      output = Agent.get(sink, & &1)
      assert output =~ "."
      assert output =~ "1m", "a minute marker keeps a long wait readable without flooding it"
      Agent.stop(sink)
    end

    test "progress output can never fail a sign-in" do
      LoginSession.reset("openai_codex")
      tick = LoginSession.on_tick("openai_codex", fn _ -> raise "stdout is a JSON-RPC pipe" end)

      # A closed or hijacked stdout is not a reason to abandon a grant the user
      # has already approved in their browser.
      assert tick.() == :continue
    end

    test "with_cancellation restores the interrupt key even when the body raises" do
      assert_raise RuntimeError, fn ->
        LoginSession.with_cancellation("openai_codex", fn -> raise "boom" end)
      end

      # Leaving the VM with a hijacked SIGINT would be a far worse bug than the
      # one the trap fixes.
      assert LoginSession.with_cancellation("openai_codex", fn -> :ok end) == :ok
    end
  end

  # ── P0-3: a 401 has somewhere to go ─────────────────────────────────────

  describe "an unauthorized response is recoverable" do
    setup do
      OptimalSystemAgent.Auth.Providers.OpenAICodex.reset_refresh_failures()

      :ok =
        SubscriptionStore.put("openai_codex", %{
          "kind" => "device_code",
          "access_token" => "stale",
          "refresh_token" => "rt",
          # Valid for another hour as far as the clock is concerned, which is
          # exactly why the proactive path cannot save this.
          "expires_at" => System.system_time(:second) + 3600,
          "base_url" => "https://stub.invalid/codex"
        })

      :ok
    end

    test "the transport reports 401 as a tagged reason, not a formatted dead end" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => %{"message" => "token expired"}}))
      end

      assert {:error, {:unauthorized, detail}} =
               OptimalSystemAgent.Providers.OpenAIResponses.chat(
                 "https://stub.invalid/codex",
                 "stale",
                 "gpt-5.2-codex",
                 [%{role: "user", content: "hi"}],
                 req_options: [plug: plug, retry: false]
               )

      assert detail =~ "token expired"
    end

    test "the provider refreshes once and retries once, and the turn succeeds" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      plug = fn conn ->
        Agent.update(calls, &[conn.request_path | &1])

        cond do
          String.ends_with?(conn.request_path, "/oauth/token") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "access_token" => "renewed",
                "refresh_token" => "rt2",
                "expires_in" => 3600
              })
            )

          # First inference attempt is refused; the one after the refresh works.
          Enum.count(Agent.get(calls, & &1), &String.ends_with?(&1, "/responses")) == 1 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(401, Jason.encode!(%{"error" => %{"message" => "expired"}}))

          true ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "output" => [
                  %{
                    "type" => "message",
                    "content" => [%{"type" => "output_text", "text" => "hello"}]
                  }
                ],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              })
            )
        end
      end

      Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :auth_req_options) end)

      assert {:ok, %{content: "hello"}} =
               OptimalSystemAgent.Providers.OpenAICodex.chat(
                 [%{role: "user", content: "hi"}],
                 req_options: [plug: plug, retry: false]
               )

      paths = Agent.get(calls, & &1)

      assert Enum.count(paths, &String.ends_with?(&1, "/responses")) == 2,
             "exactly one retry — a 401 never reached the model, so re-sending is not a duplicate"

      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "renewed"
      Agent.stop(calls)
    end

    test "a second 401 after a successful refresh is not blamed on the credential" do
      plug = fn conn ->
        if String.ends_with?(conn.request_path, "/oauth/token") do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"access_token" => "renewed", "expires_in" => 3600})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(401, Jason.encode!(%{"error" => %{"message" => "no access"}}))
        end
      end

      Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :auth_req_options) end)

      assert {:error, message} =
               OptimalSystemAgent.Providers.OpenAICodex.chat(
                 [%{role: "user", content: "hi"}],
                 req_options: [plug: plug, retry: false]
               )

      # A token minted seconds ago being refused is an entitlement problem, and
      # sending this user round a sign-in loop cannot fix it.
      assert message =~ "even after a successful token refresh"
      assert message =~ "sign-in is valid"
      refute message =~ "Run `osa setup`"
    end
  end

  describe "quota errors still never collect re-auth advice" do
    test "the rule survives everything added around it" do
      for reason <- [:subscription_required, :insufficient_credits, :login_rate_limited] do
        message = Subscription.message(reason, "ChatGPT")

        refute message =~ "re-authenticate"
        refute message =~ "Re-run setup to sign in again"
      end

      assert Subscription.message(:insufficient_credits, "ChatGPT") =~ "sign-in is still valid"
    end
  end
end
