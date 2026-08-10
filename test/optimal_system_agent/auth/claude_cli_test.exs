defmodule OptimalSystemAgent.Auth.ClaudeCliTest do
  @moduledoc """
  The Claude Code bridge is the one provider where OSA holds no credential at
  all, so these tests assert two different things from the other subscription
  providers:

  1. That it **stays** credential-free. A regression that starts storing an
     Anthropic token here would turn a sanctioned integration into a terms
     violation without anything else in the tree looking different.
  2. That the whole subprocess pipeline — argv, stdin, stream-json parsing,
     tool-call extraction, streaming — works, exercised against a **stub**
     binary rather than the real CLI, so the suite is hermetic and costs
     nobody's quota.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.ClaudeCli, as: Auth
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Providers.ClaudeCli

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-claudecli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_home = System.get_env("OSA_HOME")
    prev_bin = System.get_env("OSA_CLAUDE_CLI_BIN")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_bin,
        do: System.put_env("OSA_CLAUDE_CLI_BIN", prev_bin),
        else: System.delete_env("OSA_CLAUDE_CLI_BIN")

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # A stand-in for the `claude` binary. `body` is shell that runs with the
  # real flags in "$@", so a test can assert on what OSA actually passed.
  defp stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    System.put_env("OSA_CLAUDE_CLI_BIN", path)
    path
  end

  describe "the credential-free contract" do
    test "there is no token to hand out, and asking says so rather than returning nil" do
      assert {:error, :externally_managed} = Auth.access_token()

      assert Subscription.message(:externally_managed, "Claude") =~ "no token for OSA to use"
    end

    test "a successful connect stores account metadata and NOT a credential", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226 (Claude Code)" ;;
        auth) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.c","subscriptionType":"max","orgName":"Acme"}' ;;
      esac
      """)

      assert {:ok, entry} = Auth.login(io: fn _ -> :ok end)
      assert entry["kind"] == "external_cli"
      assert entry["account_id"] == "a@b.c"
      assert entry["plan_type"] == "max"

      stored = SubscriptionStore.fetch("claude_cli")

      for forbidden <- ~w(access_token refresh_token id_token client_id code_verifier) do
        refute Map.has_key?(stored, forbidden),
               "the Claude Code bridge must never store #{forbidden}: holding an Anthropic " <>
                 "subscription credential in a third-party tool is the thing this design avoids"
      end
    end

    test "status is a pure read and reports no expiry it cannot know", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"pro"}' ;;
      esac
      """)

      assert %{connected?: false} = Auth.status()
      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)

      status = Auth.status()
      assert status.connected? == true
      assert status.plan == "pro"
      assert status.expires_at == nil
      assert status.expired? == false
    end

    test "sign-out forgets OSA's marker only", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}' ;;
      esac
      """)

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      assert :ok = Auth.logout()
      assert %{connected?: false} = Auth.status()
    end

    test "sign-out sticks: a still-signed-in CLI does not re-seed the marker", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}' ;;
      esac
      """)

      assert {:ok, _} = Auth.login(io: fn _ -> :ok end)
      assert :ok = Auth.logout()

      # The CLI is still signed in. Anything that re-created the marker here
      # would silently undo the user's disconnect the next time a status
      # screen was drawn.
      assert {:error, :not_connected} = Auth.live_status()
      assert %{connected?: false} = Auth.status()
      assert is_nil(SubscriptionStore.fetch("claude_cli"))
    end
  end

  describe "prerequisite failures are actionable" do
    test "a missing binary names the install step, not 'try again'" do
      System.put_env("OSA_CLAUDE_CLI_BIN", "/nonexistent/claude")

      lines = capture_login()

      assert Enum.any?(lines, &(&1 =~ "not installed"))
      assert Enum.any?(lines, &(&1 =~ "OSA_CLAUDE_CLI_BIN"))
    end

    test "a signed-out CLI names the command to run, and says why OSA cannot run it", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":false}' ;;
      esac
      """)

      lines = capture_login()

      assert Enum.any?(lines, &(&1 =~ "claude auth login"))
      assert Enum.any?(lines, &(&1 =~ "setup-token"))

      assert Enum.any?(lines, &(&1 =~ "cannot sign you in")),
             "the user must be told OSA is not allowed to offer Claude login, not left assuming it is broken"
    end

    test "an old CLI is refused with the upgrade command", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "1.0.4" ;;
        auth) echo '{"loggedIn":true}' ;;
      esac
      """)

      assert {:error, {:cli_too_old, "1.0.4"}} = Auth.login(io: fn _ -> :ok end)
      assert Subscription.message({:cli_too_old, "1.0.4"}, "Claude") =~ "claude update"
    end

    test "an unknown version is allowed rather than blocking a newer CLI" do
      assert Auth.version_ok?(nil)
      assert Auth.version_ok?("99.0.0")
      refute Auth.version_ok?("1.9.9")
    end

    test "sign-in is always offered, because the missing piece is installable" do
      System.put_env("OSA_CLAUDE_CLI_BIN", "/nonexistent/claude")

      assert Auth.available?(),
             "claude_cli is oauth-only; reporting it unavailable would collapse it to a key " <>
               "prompt for a provider that has no key"

      refute Auth.installed?()
    end

    test "unreadable status output is not mistaken for being signed out", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo 'not json at all' ;;
      esac
      """)

      assert {:error, :cli_status_unreadable} = Auth.probe()
    end

    test "a banner printed before the JSON does not break the probe", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo 'A new version is available!'; echo '{"loggedIn":true,"email":"x@y.z"}' ;;
      esac
      """)

      assert {:ok, %{email: "x@y.z"}} = Auth.probe()
    end
  end

  describe "dispatch and catalog" do
    test "the provider is reachable through the shared Subscription façade" do
      assert Subscription.impl("claude_cli") == Auth
      assert Subscription.supported?("claude_cli")
      assert "claude_cli" in Subscription.supported()
    end

    test "it is routable in the Registry before it is selectable in the picker" do
      assert :claude_cli in OptimalSystemAgent.Providers.Registry.list_providers(),
             "a provider you can select but never use is worse than one that is absent"
    end

    test "the catalog entry declares sign-in and carries no key affordance" do
      entry = Enum.find(OptimalSystemAgent.Onboarding.providers_list(), &(&1.id == "claude_cli"))

      assert entry, "claude_cli must appear in the picker on all three setup surfaces"
      assert entry.auth_modes == [:oauth]
      assert entry.requires_key == false
      assert entry.env_var == nil
      assert entry.subscription.kind == :external_cli
    end

    test "setup routes it to sign-in, never to a key prompt" do
      assert OptimalSystemAgent.Onboarding.auth_route("claude_cli", nil) == :oauth
      assert OptimalSystemAgent.Onboarding.auth_route("claude_cli", :api_key) == :oauth

      assert OptimalSystemAgent.Onboarding.auth_options("claude_cli") == [],
             "a single-mode provider asks no question; it just runs its one path"
    end

    test "the health check reflects the CLI's live state, not a stale marker", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}' ;;
      esac
      """)

      # The health check IS the connect step for this provider WHEN a setup
      # surface is driving it — it is what the TUI wizard fires at its verify
      # stage, and there is no browser round-trip to separate the two. The
      # flag is what makes that true; see the resurrection test below for what
      # happens without it.
      assert {:ok, ok} =
               OptimalSystemAgent.Onboarding.health_check(%{
                 "provider" => "claude_cli",
                 "during_setup" => true
               })

      assert SubscriptionStore.fetch("claude_cli")
      assert ok.auth_mode == "subscription"
      assert ok.plan == "max"

      # The user signs out in Claude Code. OSA's marker still says connected;
      # the health check must not.
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":false}' ;;
      esac
      """)

      assert {:error, err} =
               OptimalSystemAgent.Onboarding.health_check(%{
                 "provider" => "claude_cli",
                 "during_setup" => true
               })

      assert err.error == "not_connected"
      assert err.message =~ "claude auth login"
    end

    # The regression this file already guarded at the `live_status/0` level,
    # now guarded at the level a real user reaches: `POST
    # /onboarding/health-check`, which called `connect/0` directly and so
    # rebuilt the marker on the next status refresh after a sign-out. The
    # symptom was that `osa logout` appeared to do nothing.
    test "a status-surface health check never resurrects a marker the user removed", %{dir: dir} do
      stub(dir, "claude", ~S"""
      case "$1" in
        --version) echo "2.1.226" ;;
        auth) echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}' ;;
      esac
      """)

      {:ok, _} =
        OptimalSystemAgent.Onboarding.health_check(%{
          "provider" => "claude_cli",
          "during_setup" => true
        })

      assert SubscriptionStore.fetch("claude_cli")

      :ok = OptimalSystemAgent.Auth.Subscription.logout("claude_cli")
      refute SubscriptionStore.fetch("claude_cli")

      # A signed-in CLI is NOT permission to re-create the marker. Without the
      # setup flag the honest answer is "not connected", even though the probe
      # would happily succeed.
      assert {:error, err} =
               OptimalSystemAgent.Onboarding.health_check(%{"provider" => "claude_cli"})

      assert err.error == "not_connected"

      refute SubscriptionStore.fetch("claude_cli"),
             "a status check must never write a credential marker"

      # And a caller cannot talk its way past the gate by asserting a string
      # or a truthy-looking value; only a literal `true` from a trusted caller
      # counts, and `channels/http.ex` strips the field from request bodies
      # before it ever reaches here.
      assert {:error, _} =
               OptimalSystemAgent.Onboarding.health_check(%{
                 "provider" => "claude_cli",
                 "during_setup" => "true"
               })

      refute SubscriptionStore.fetch("claude_cli")
    end
  end

  describe "prompt assembly" do
    test "system turns are lifted out of the conversation, not left in it" do
      {system, turns} =
        ClaudeCli.split_system([
          %{role: "system", content: "A"},
          %{role: "user", content: "hi"},
          %{role: "system", content: "B"}
        ])

      assert system == "A\n\nB"
      assert length(turns) == 1
    end

    test "tools are declared in the system prompt, since the CLI takes no schemas" do
      prompt =
        ClaudeCli.build_system_prompt("You are OSA.", [
          %{name: "read_file", description: "Read a file.", parameters: %{"type" => "object"}}
        ])

      assert prompt =~ "You are OSA."
      assert prompt =~ "<tool_call>"
      assert prompt =~ "read_file"
      assert prompt =~ "Read a file."
    end

    test "no tools means no protocol section, so a chat turn is not polluted" do
      assert ClaudeCli.build_system_prompt("You are OSA.", []) == "You are OSA."
    end

    test "a single turn is sent as-is; history is quoted around it" do
      assert ClaudeCli.render_turns([%{role: "user", content: "hello"}]) == "hello"

      rendered =
        ClaudeCli.render_turns([
          %{role: "user", content: "first"},
          %{role: "assistant", content: "reply"},
          %{role: "tool", name: "read_file", content: "contents"},
          %{role: "user", content: "latest"}
        ])

      assert rendered =~ "<transcript>"
      assert rendered =~ "[assistant]\nreply"
      assert rendered =~ "[tool result from read_file]"
      assert rendered =~ "latest"
    end
  end

  describe "the subprocess transport" do
    # One canned stream-json conversation, replayed by the stub. Shapes are
    # copied from a real CLI 2.1.226 run.
    defp emit_stub(dir, events) do
      lines = Enum.map_join(events, "\n", &Jason.encode!/1)

      stub(dir, "claude", """
      cat > /dev/null
      cat <<'OSA_EOF'
      #{lines}
      OSA_EOF
      """)
    end

    test "a plain reply comes back as content", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "assistant",
          "message" => %{"model" => "claude-sonnet-4-5-20250929", "content" => [%{"type" => "text", "text" => "hello"}]}
        },
        %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "hello"}
      ])

      assert {:ok, %{content: "hello", tool_calls: []}} =
               ClaudeCli.chat([%{role: "user", content: "hi"}])

      assert ClaudeCli.last_resolved_model() == "claude-sonnet-4-5-20250929"
    end

    test "a tool call is parsed out and stripped from the visible content", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  ~s(Sure.\n<tool_call>{"name":"read_file","arguments":{"path":"/etc/hostname"}}</tool_call>)
              }
            ]
          }
        },
        %{"type" => "result", "is_error" => false, "result" => ""}
      ])

      assert {:ok, %{content: content, tool_calls: [call]}} =
               ClaudeCli.chat([%{role: "user", content: "read it"}])

      assert call.name == "read_file"
      assert call.arguments == %{"path" => "/etc/hostname"}
      assert content == "Sure."
      refute content =~ "tool_call"
    end

    test "an API error from the CLI surfaces with its own text, not a generic failure", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "result",
          "is_error" => true,
          "api_error_status" => 404,
          "result" => "There's an issue with the selected model"
        }
      ])

      assert {:error, message} = ClaudeCli.chat([%{role: "user", content: "hi"}])
      assert message =~ "404"
      assert message =~ "issue with the selected model"
    end

    test "a non-zero exit carries the CLI's stderr, so the failure is explainable", %{dir: dir} do
      stub(dir, "claude", """
      cat > /dev/null
      echo "error: unknown option '--tools'" >&2
      exit 2
      """)

      assert {:error, message} = ClaudeCli.chat([%{role: "user", content: "hi"}])
      assert message =~ "unknown option"
    end

    test "streaming emits deltas once and does not duplicate the final content", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => "1, 2, "}
          }
        },
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => "3"}
          }
        },
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "1, 2, 3"}]}},
        %{"type" => "result", "is_error" => false, "result" => "1, 2, 3"}
      ])

      parent = self()

      assert :ok =
               ClaudeCli.chat_stream([%{role: "user", content: "count"}], fn event ->
                 send(parent, event)
               end)

      deltas = collect_deltas()
      assert Enum.join(deltas) == "1, 2, 3"
      assert_received {:done, %{content: "1, 2, 3", tool_calls: []}}
    end

    test "tool-call markup is never streamed into the transcript", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "stream_event",
          "event" => %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => "ok <tool"}}
        },
        %{
          "type" => "stream_event",
          "event" => %{
            "type" => "content_block_delta",
            "delta" => %{
              "type" => "text_delta",
              "text" => ~s(_call>{"name":"read_file","arguments":{}}</tool_call>)
            }
          }
        },
        %{"type" => "result", "is_error" => false, "result" => ""}
      ])

      parent = self()

      assert :ok =
               ClaudeCli.chat_stream([%{role: "user", content: "go"}], fn event ->
                 send(parent, event)
               end)

      streamed = Enum.join(collect_deltas())

      refute streamed =~ "tool_call",
             "protocol markup must never reach the user's transcript, even split across deltas"

      assert_received {:done, %{tool_calls: [%{name: "read_file"}]}}
    end

    test "the conversation is passed on stdin, never in argv", %{dir: dir} do
      marker = "secret-prompt-#{System.unique_integer([:positive])}"
      argv_file = Path.join(dir, "argv.txt")
      stdin_file = Path.join(dir, "stdin.txt")

      stub(dir, "claude", """
      printf '%s\\n' "$@" > #{argv_file}
      cat > #{stdin_file}
      echo '{"type":"result","is_error":false,"result":"ok"}'
      """)

      assert {:ok, _} = ClaudeCli.chat([%{role: "user", content: marker}])

      argv = File.read!(argv_file)
      stdin = File.read!(stdin_file)

      refute argv =~ marker,
             "the prompt must not appear in argv — `ps` is readable by every local user"

      assert stdin =~ marker
    end

    test "the isolation flags are actually passed, since the loop depends on them", %{dir: dir} do
      argv_file = Path.join(dir, "argv.txt")

      stub(dir, "claude", """
      printf '%s\\n' "$@" > #{argv_file}
      cat > /dev/null
      echo '{"type":"result","is_error":false,"result":"ok"}'
      """)

      assert {:ok, _} = ClaudeCli.chat([%{role: "system", content: "OSA prompt"}, %{role: "user", content: "hi"}])

      argv = File.read!(argv_file) |> String.split("\n")

      for flag <- ~w(--tools --setting-sources --strict-mcp-config --no-session-persistence --system-prompt) do
        assert flag in argv,
               "#{flag} is what keeps Claude Code from running its own agent instead of answering OSA's"
      end

      assert "OSA prompt" in argv, "OSA's system prompt must replace Claude Code's, not be dropped"
    end

    test "the request's temporary file is private and removed afterwards", %{dir: dir} do
      seen = Path.join(dir, "seen.txt")

      stub(dir, "claude", """
      printf '%s' "$OSA_CLAUDE_STDIN" > #{seen}
      cat > /dev/null
      echo '{"type":"result","is_error":false,"result":"ok"}'
      """)

      assert {:ok, _} = ClaudeCli.chat([%{role: "user", content: "hi"}])

      path = File.read!(seen)
      refute File.exists?(path), "the prompt file must not outlive the request"
    end

    test "an inherited ANTHROPIC_API_KEY is cleared, so billing does not silently change", %{dir: dir} do
      seen = Path.join(dir, "env.txt")
      prev = System.get_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-should-not-leak")

      on_exit(fn ->
        if prev,
          do: System.put_env("ANTHROPIC_API_KEY", prev),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end)

      stub(dir, "claude", """
      printf '[%s]' "$ANTHROPIC_API_KEY" > #{seen}
      cat > /dev/null
      echo '{"type":"result","is_error":false,"result":"ok"}'
      """)

      assert {:ok, _} = ClaudeCli.chat([%{role: "user", content: "hi"}])

      assert File.read!(seen) == "[]",
             "a key inherited from OSA's environment would move the user from plan-metered to " <>
               "per-token billing on the provider they chose to avoid that"
    end

    test "a hung CLI is abandoned rather than hanging the turn forever", %{dir: dir} do
      stub(dir, "claude", """
      cat > /dev/null
      sleep 30
      """)

      assert {:error, message} =
               ClaudeCli.chat([%{role: "user", content: "hi"}], receive_timeout: 300)

      assert message =~ "did not finish in time"
    end
  end

  describe "model reporting" do
    test "only CLI aliases are advertised — no invented dated model ids" do
      for model <- ClaudeCli.available_models() do
        refute model =~ ~r/\d{8}/,
               "a hardcoded dated model id here becomes a confident lie the next time Anthropic " <>
                 "ships one; the alias is what the CLI actually accepts"
      end

      assert ClaudeCli.default_model() in ClaudeCli.available_models()
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp capture_login do
    parent = self()
    Auth.login(io: fn line -> send(parent, {:line, line}) end)
    drain_lines([])
  end

  defp drain_lines(acc) do
    receive do
      {:line, line} -> drain_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_deltas(acc \\ []) do
    receive do
      {:text_delta, t} -> collect_deltas([t | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
