defmodule OptimalSystemAgent.Auth.CopilotCliTest do
  @moduledoc """
  The Copilot bridge shares `claude_cli`'s architecture but differs in the one
  place that mattered most to get right: there is no offline way to confirm a
  Copilot sign-in, and confirming it online costs the operator real money. So
  alongside the usual wiring these tests pin two properties specifically:

  1. **No inference call is ever made to answer a status question.** A stub
     binary that would bill on invocation is used to prove the auth path never
     runs it.
  2. **"Unknown" is representable and is not rounded to "connected" or
     "signed out".** Both of those would be fabrications when the credential
     is in the OS keychain.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.CopilotCli, as: Auth
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Providers.CopilotCli

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-copilotcli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    saved =
      for var <- ["OSA_HOME", "OSA_COPILOT_CLI_BIN", "PATH" | Auth.token_env_vars()],
          into: %{},
          do: {var, System.get_env(var)}

    System.put_env("OSA_HOME", dir)
    # Every token env var must start unset; the host running the suite may
    # legitimately have GITHUB_TOKEN exported, which would silently make the
    # "unknown" cases untestable.
    Enum.each(Auth.token_env_vars(), &System.delete_env/1)
    # Put the scratch dir FIRST on PATH so a stubbed `gh` shadows any real
    # one, without removing /bin — the transport needs a real `sh`.
    System.put_env("PATH", dir <> ":" <> (saved["PATH"] || ""))

    # Default: `gh` reports not-authenticated. Without this, a developer with
    # a live `gh` session would see the "no visible signal" cases silently
    # pass for the wrong reason.
    File.write!(Path.join(dir, "gh"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(dir, "gh"), 0o755)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp stub_copilot(dir, body) do
    path = stub(dir, "copilot", body)
    System.put_env("OSA_COPILOT_CLI_BIN", path)
    path
  end

  defp version_stub do
    ~S"""
    case "$1" in --version) echo "1.0.79" ;; esac
    """
  end

  describe "no status question ever costs money" do
    test "the auth path never invokes the CLI for inference", %{dir: dir} do
      billed = Path.join(dir, "billed")

      # This stub records ANY invocation that is not `--version`. If the auth
      # path ever shells out to ask Copilot something, this file appears.
      stub_copilot(dir, """
      case "$1" in
        --version) echo "1.0.79" ;;
        *) echo "INVOKED" >> #{billed} ;;
      esac
      """)

      _ = Auth.probe()
      {:ok, _} = Auth.connect()
      _ = Auth.status()
      _ = Auth.live_status()
      _ = Subscription.status("copilot_cli")

      refute File.exists?(billed),
             "an auth or status path invoked the Copilot CLI; every such call is a metered " <>
               "request, and `osa doctor` must be free to run"
    end
  end

  describe "zero-cost sign-in signals" do
    test "an explicit token env var is a positive signal, and its value is never returned", %{dir: dir} do
      stub_copilot(dir, version_stub())
      System.put_env("GH_TOKEN", "gho_supersecretvalue")

      assert {:ok, %{verified: true, source: "env:GH_TOKEN"}} = Auth.probe()
      assert Auth.token_env_var() == "GH_TOKEN"

      {:ok, entry} = Auth.connect()

      refute Enum.any?(Map.values(entry), fn v -> v == "gho_supersecretvalue" end),
             "the token's VALUE must never reach the credential store; only the variable's name"
    end

    test "precedence follows Copilot's own documented order", %{dir: dir} do
      stub_copilot(dir, version_stub())
      System.put_env("GITHUB_TOKEN", "a")
      System.put_env("GH_TOKEN", "b")
      assert Auth.token_env_var() == "GH_TOKEN"

      System.put_env("COPILOT_GITHUB_TOKEN", "c")
      assert Auth.token_env_var() == "COPILOT_GITHUB_TOKEN"
    end

    test "a gh session with an OAuth token is a positive signal", %{dir: dir} do
      stub_copilot(dir, version_stub())

      stub(dir, "gh", ~S"""
      echo "github.com"
      echo "  ✓ Logged in to github.com account robertohluna (keyring)"
      echo "  - Token: gho_************"
      """)

      assert {:ok, %{verified: true, source: "gh", account: "robertohluna"}} = Auth.probe()
    end

    test "a gh session on a CLASSIC PAT is not a signal — Copilot rejects those", %{dir: dir} do
      stub_copilot(dir, version_stub())

      stub(dir, "gh", ~S"""
      echo "  ✓ Logged in to github.com account someone (keyring)"
      echo "  - Token: ghp_************"
      """)

      assert {:ok, %{verified: false, source: "cli_managed"}} = Auth.probe(),
             "ghp_ classic PATs are not accepted by Copilot, so a gh session holding one is " <>
               "not evidence of a usable credential and must not be reported as one"
    end

    test "a fine-grained PAT IS a signal", %{dir: dir} do
      stub_copilot(dir, version_stub())
      stub(dir, "gh", ~S(echo "  - Token: github_pat_11ABC"))

      assert {:ok, %{verified: true, source: "gh"}} = Auth.probe()
    end
  end

  describe "\"unknown\" is a first-class answer" do
    test "an installed CLI with no visible signal reports unverified, not connected or signed out",
         %{dir: dir} do
      stub_copilot(dir, version_stub())

      assert {:ok, %{verified: false, source: "cli_managed"}} = Auth.probe()

      {:ok, entry} = Auth.connect()
      assert entry["verified"] == false
      refute Auth.verified?() == true

      # The provider is still usable — the credential may be in the keychain.
      assert Auth.status().connected? == true
    end

    test "the health check says so plainly instead of guessing", %{dir: dir} do
      stub_copilot(dir, version_stub())

      assert {:ok, health} =
               OptimalSystemAgent.Onboarding.health_check(%{
                 "provider" => "copilot_cli",
                 "during_setup" => true
               })

      assert health.verified == :unverified
      assert health.message =~ "cannot confirm"
      assert health.message =~ "will not make a"
      assert health.message =~ "copilot login"
    end

    test "a confirmed signal upgrades the health check to verified", %{dir: dir} do
      stub_copilot(dir, version_stub())
      System.put_env("COPILOT_GITHUB_TOKEN", "gho_x")

      assert {:ok, %{verified: true, auth_mode: "subscription"}} =
               OptimalSystemAgent.Onboarding.health_check(%{
                 "provider" => "copilot_cli",
                 "during_setup" => true
               })
    end

    # Copilot's version of the resurrection bug is the worse of the two:
    # `probe/0` answers "present but unverified" for nothing more than the
    # `copilot` binary existing on PATH, so a status surface calling
    # `connect/0` would manufacture a connected entry out of an `ls` — with no
    # sign-in evidence at all — for a user who had just signed out.
    test "a status-surface health check never fabricates a connection from a binary on PATH",
         %{dir: dir} do
      stub_copilot(dir, version_stub())

      {:ok, _} =
        OptimalSystemAgent.Onboarding.health_check(%{
          "provider" => "copilot_cli",
          "during_setup" => true
        })

      assert SubscriptionStore.fetch("copilot_cli")

      :ok = OptimalSystemAgent.Auth.Subscription.logout("copilot_cli")
      refute SubscriptionStore.fetch("copilot_cli")

      assert {:error, err} =
               OptimalSystemAgent.Onboarding.health_check(%{"provider" => "copilot_cli"})

      assert err.error == "not_connected"

      refute SubscriptionStore.fetch("copilot_cli"),
             "the binary being on PATH is not evidence of anything and must not create a marker"
    end

    test "an unverified marker is reported as unverified by the status contract", %{dir: dir} do
      stub_copilot(dir, version_stub())
      {:ok, _} = Auth.connect()

      status = Auth.status()

      assert status.connected? == true,
             "the user asked for this provider, so OSA records that"

      refute status.verified?,
             "but OSA has no evidence of a sign-in, and must not imply that it does"
    end
  end

  describe "the credential-free contract" do
    test "no token-shaped key can appear in the stored entry", %{dir: dir} do
      stub_copilot(dir, version_stub())
      System.put_env("GH_TOKEN", "gho_x")
      {:ok, _} = Auth.connect()

      stored = SubscriptionStore.fetch("copilot_cli")

      for forbidden <- ~w(access_token refresh_token id_token client_id code_verifier token) do
        refute Map.has_key?(stored, forbidden),
               "the Copilot bridge must never store #{forbidden}: GitHub's CLI holds the " <>
                 "credential, and a regression that starts copying it here changes what this " <>
                 "integration IS"
      end
    end

    test "the store file is 0600", %{dir: dir} do
      stub_copilot(dir, version_stub())
      {:ok, _} = Auth.connect()

      {:ok, stat} = File.stat(SubscriptionStore.path())
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "there is no token to hand out" do
      assert {:error, :externally_managed} = Auth.access_token()
    end

    test "sign-out sticks even while gh is still logged in", %{dir: dir} do
      stub_copilot(dir, version_stub())
      stub(dir, "gh", ~S(echo "  - Token: gho_x"))

      {:ok, _} = Auth.connect()
      assert :ok = Auth.logout()

      assert {:error, :not_connected} = Auth.live_status(),
             "a status surface must not resurrect a marker the user removed just because gh " <>
               "happens to still be authenticated"

      assert %{connected?: false} = Auth.status()
      assert is_nil(SubscriptionStore.fetch("copilot_cli"))
    end
  end

  describe "prerequisites" do
    test "a missing binary names the install step and the lookalike package" do
      System.put_env("OSA_COPILOT_CLI_BIN", "/nonexistent/copilot")
      parent = self()
      assert {:error, :cli_not_installed} = Auth.login(io: &send(parent, {:line, &1}))

      lines = drain()
      assert Enum.any?(lines, &(&1 =~ "npm install -g @github/copilot"))

      assert Enum.any?(lines, &(&1 =~ "copilot-language-server")),
             "the ACP registry has two similarly-named entries and only one is this CLI; " <>
               "installing the wrong one yields a process that handshakes and never answers"
    end

    test "sign-in is always offered, because the missing pieces are user-fixable" do
      System.put_env("OSA_COPILOT_CLI_BIN", "/nonexistent/copilot")
      assert Auth.available?()
      refute Auth.installed?()
    end

    test "an old CLI is refused with the upgrade command", %{dir: dir} do
      stub_copilot(dir, ~S"""
      case "$1" in --version) echo "0.0.397" ;; esac
      """)
      assert {:error, {:cli_too_old, "0.0.397"}} = Auth.login(io: fn _ -> :ok end)
    end
  end

  describe "dispatch and catalog" do
    test "reachable through the shared Subscription façade" do
      assert Subscription.impl("copilot_cli") == Auth
      assert "copilot_cli" in Subscription.supported()
    end

    test "routable in the Registry before it is selectable in the picker" do
      assert :copilot_cli in OptimalSystemAgent.Providers.Registry.list_providers(),
             "a provider you can select but never use is worse than one that is absent"
    end

    test "the catalog entry declares sign-in and carries no key affordance" do
      entry = Enum.find(OptimalSystemAgent.Onboarding.providers_list(), &(&1.id == "copilot_cli"))

      assert entry
      assert entry.auth_modes == [:oauth]
      assert entry.requires_key == false
      assert entry.env_var == nil
      assert entry.subscription.kind == :external_cli
    end

    test "setup routes it to sign-in, never to a key prompt" do
      assert OptimalSystemAgent.Onboarding.auth_route("copilot_cli", nil) == :oauth
      assert OptimalSystemAgent.Onboarding.auth_route("copilot_cli", :api_key) == :oauth
    end
  end

  describe "the probe answers about the USER's account, not the workspace's" do
    # `cmd/2` passed only `NO_COLOR`, so everything else in OSA's environment
    # reached the probed CLI — including a `GITHUB_TOKEN` / `GH_TOKEN` a
    # workspace `.env`, a CI runner or a shell export had supplied. The probe
    # then reported a sign-in that belonged to that token, and the user was
    # told they were connected as themselves.

    test "a workspace-supplied GITHUB_TOKEN is invisible to the `gh` probe", %{dir: dir} do
      stub(dir, "gh", """
      if [ -n "$GITHUB_TOKEN" ]; then
        echo "  github.com"
        echo "    - Logged in to github.com account workspace-bot"
        echo "    - Token: gho_theworkspacestoken"
        exit 0
      fi
      exit 1
      """)

      System.put_env("GITHUB_TOKEN", "gho_theworkspacestoken")

      assert Auth.gh_session() == :none,
             "the probe inherited a token the WORKSPACE supplied and reported it as the " <>
               "operator's own GitHub sign-in"
    end

    test "GH_HOST cannot silently redirect the probe at another server", %{dir: dir} do
      stub(dir, "gh", """
      echo "host=${GH_HOST:-github.com}"
      exit 1
      """)

      System.put_env("GH_HOST", "ghe.evil.example")

      assert {out, _} = System.cmd(Path.join(dir, "gh"), [], env: Auth.probe_env())
      assert out =~ "host=github.com"
    after
      System.delete_env("GH_HOST")
    end

    test "every credential var the provider itself recognises is nulled for the subprocess" do
      env = Auth.probe_env()

      for var <- Auth.token_env_vars() do
        assert {var, nil} in env,
               "#{var} is a signal this provider reads, so it must not also be able to " <>
                 "answer the probe"
      end

      assert {"GH_HOST", nil} in env
      assert {"NO_COLOR", "1"} in env, "output must stay parseable"
    end
  end

  describe "the subprocess transport" do
    defp emit_stub(dir, events) do
      lines = Enum.map_join(events, "\n", &Jason.encode!/1)

      stub_copilot(dir, """
      cat > /dev/null
      cat <<'OSA_EOF'
      #{lines}
      OSA_EOF
      """)
    end

    test "a plain reply comes back as content", %{dir: dir} do
      emit_stub(dir, [
        %{"type" => "assistant.message", "data" => %{"model" => "gpt-5-mini", "content" => "hello"}},
        %{"type" => "result", "exitCode" => 0, "usage" => %{"premiumRequests" => 0.33}}
      ])

      assert {:ok, %{content: "hello", tool_calls: []}} =
               CopilotCli.chat([%{role: "user", content: "hi"}])

      assert CopilotCli.last_resolved_model() == "gpt-5-mini"
      assert CopilotCli.last_usage()["premiumRequests"] == 0.33
    end

    test "a tool call is parsed out and stripped from the visible content", %{dir: dir} do
      emit_stub(dir, [
        %{
          "type" => "assistant.message",
          "data" => %{
            "content" =>
              ~s(Sure.\n<tool_call>{"name":"read_file","arguments":{"path":"/etc/hostname"}}</tool_call>)
          }
        },
        %{"type" => "result", "exitCode" => 0}
      ])

      assert {:ok, %{content: "Sure.", tool_calls: [call]}} =
               CopilotCli.chat([%{role: "user", content: "read it"}])

      assert call.name == "read_file"
      assert call.arguments == %{"path" => "/etc/hostname"}
    end

    test "the account's real model list is learned from the router, never invented", %{dir: dir} do
      assert CopilotCli.available_models() == ["auto"],
             "before any call, the only honest entry is `auto` — a hardcoded catalogue here " <>
               "would be a guess about a per-account list"

      emit_stub(dir, [
        %{
          "type" => "session.auto_mode_resolved",
          "data" => %{
            "availableModels" => ["claude-haiku-4.5", "gpt-5-mini"],
            "chosenModel" => "gpt-5-mini"
          }
        },
        %{"type" => "result", "exitCode" => 0}
      ])

      assert {:ok, _} = CopilotCli.chat([%{role: "user", content: "hi"}])
      assert CopilotCli.available_models() == ["auto", "claude-haiku-4.5", "gpt-5-mini"]
    end

    test "streaming emits deltas once and does not duplicate the final content", %{dir: dir} do
      emit_stub(dir, [
        %{"type" => "assistant.message_delta", "data" => %{"deltaContent" => "1, 2, "}},
        %{"type" => "assistant.message_delta", "data" => %{"deltaContent" => "3"}},
        %{"type" => "assistant.message", "data" => %{"content" => "1, 2, 3"}},
        %{"type" => "result", "exitCode" => 0}
      ])

      parent = self()
      assert :ok = CopilotCli.chat_stream([%{role: "user", content: "c"}], &send(parent, &1))

      assert Enum.join(collect_deltas()) == "1, 2, 3"
      assert_received {:done, %{content: "1, 2, 3"}}
    end

    test "the loop-suppression flag is actually passed", %{dir: dir} do
      argv_file = Path.join(dir, "argv.txt")

      stub_copilot(dir, """
      printf '%s\\n' "$@" > #{argv_file}
      cat > /dev/null
      echo '{"type":"result","exitCode":0}'
      """)

      assert {:ok, _} = CopilotCli.chat([%{role: "user", content: "hi"}])
      argv = File.read!(argv_file) |> String.split("\n")

      assert "--available-tools=osa_none" in argv,
             "an EMPTY --available-tools is ignored by the CLI and tools stay live; the " <>
               "nonexistent-tool-name form is what actually disables Copilot's agent loop"

      for flag <- ~w(--disable-builtin-mcps --no-ask-user --no-custom-instructions --no-remote --no-auto-update) do
        assert flag in argv
      end

      refute "--model" in argv,
             "the default is Copilot's own router; passing a model OSA merely believes is " <>
               "available fails turns that would otherwise have worked"
    end

    test "an explicitly chosen model IS passed", %{dir: dir} do
      argv_file = Path.join(dir, "argv.txt")

      stub_copilot(dir, """
      printf '%s\\n' "$@" > #{argv_file}
      cat > /dev/null
      echo '{"type":"result","exitCode":0}'
      """)

      assert {:ok, _} = CopilotCli.chat([%{role: "user", content: "hi"}], model: "gpt-5-mini")
      argv = File.read!(argv_file) |> String.split("\n")
      assert "--model" in argv
      assert "gpt-5-mini" in argv
    end

    test "the conversation goes on stdin, never in argv", %{dir: dir} do
      marker = "secret-prompt-#{System.unique_integer([:positive])}"
      argv_file = Path.join(dir, "argv.txt")
      stdin_file = Path.join(dir, "stdin.txt")

      stub_copilot(dir, """
      printf '%s\\n' "$@" > #{argv_file}
      cat > #{stdin_file}
      echo '{"type":"result","exitCode":0}'
      """)

      assert {:ok, _} = CopilotCli.chat([%{role: "user", content: marker}])

      refute File.read!(argv_file) =~ marker,
             "Copilot's -p flag takes the prompt as an argv value, which would publish the " <>
               "whole conversation to every local user via ps; stdin is used instead"

      assert File.read!(stdin_file) =~ marker
    end

    test "a non-zero exit carries the CLI's stderr", %{dir: dir} do
      stub_copilot(dir, """
      cat > /dev/null
      echo "error: not authenticated" >&2
      exit 1
      """)

      assert {:error, message} = CopilotCli.chat([%{role: "user", content: "hi"}])
      assert message =~ "not authenticated"
    end

    test "a silent failure points at the one thing OSA cannot check for you", %{dir: dir} do
      stub_copilot(dir, """
      cat > /dev/null
      exit 1
      """)

      assert {:error, message} = CopilotCli.chat([%{role: "user", content: "hi"}])
      assert message =~ "copilot login"
      assert message =~ "billed request"
    end

    test "the prompt file is private and removed afterwards", %{dir: dir} do
      seen = Path.join(dir, "seen.txt")

      stub_copilot(dir, """
      printf '%s' "$OSA_COPILOT_STDIN" > #{seen}
      cat > /dev/null
      echo '{"type":"result","exitCode":0}'
      """)

      assert {:ok, _} = CopilotCli.chat([%{role: "user", content: "hi"}])
      refute File.exists?(File.read!(seen))
    end

    test "a hung CLI is abandoned rather than hanging the turn", %{dir: dir} do
      stub_copilot(dir, "cat > /dev/null\nsleep 30")

      assert {:error, message} =
               CopilotCli.chat([%{role: "user", content: "hi"}], receive_timeout: 300)

      assert message =~ "did not finish in time"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp drain(acc \\ []) do
    receive do
      {:line, l} -> drain([l | acc])
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
