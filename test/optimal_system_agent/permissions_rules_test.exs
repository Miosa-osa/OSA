defmodule OptimalSystemAgent.PermissionsRulesTest do
  @moduledoc """
  WS3 permission engine: Tool(content) parser, CC shell rule matching
  (exact / prefix:* / wildcard w/ escapes / dotAll), compound-command
  splitting, settings-cascade provenance, MCP integration, legacy
  colon-rule migration, and bypass-immune safety paths.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Settings

  @flag_file Path.join(System.tmp_dir!(), "osa-ws3-flag-settings.json")

  setup do
    legacy = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(legacy), do: File.rm(legacy)

    prior_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)

    on_exit(fn ->
      case prior_flag do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        path -> Application.put_env(:optimal_system_agent, :settings_flag_path, path)
      end

      File.rm(@flag_file)
      if is_binary(legacy), do: File.rm(legacy)
      Settings.reset_cache()
    end)

    :ok
  end

  defp put_flag_permissions(perms) do
    File.write!(@flag_file, Jason.encode!(%{"permissions" => perms}))
    Application.put_env(:optimal_system_agent, :settings_flag_path, @flag_file)
    Settings.reset_cache()
  end

  describe "parse_rule/1" do
    test "tool-only, content, escaped parens, CC aliases" do
      assert Permissions.parse_rule("Bash") == %{tool: "shell_execute", content: nil}

      assert Permissions.parse_rule("Bash(npm install)") ==
               %{tool: "shell_execute", content: "npm install"}

      assert Permissions.parse_rule("Bash(python -c \"print\\(1\\)\")") ==
               %{tool: "shell_execute", content: "python -c \"print(1)\""}
    end

    test "empty / star content and malformed rules degrade to tool-only" do
      assert Permissions.parse_rule("Bash()").content == nil
      assert Permissions.parse_rule("Bash(*)").content == nil
      assert Permissions.parse_rule("(foo)").content == nil
    end

    test "rule_to_string escapes parens" do
      assert Permissions.rule_to_string("shell_execute", "print(1)") ==
               "shell_execute(print\\(1\\))"
    end
  end

  describe "shell rule matching" do
    test "exact / prefix:* / boundary" do
      assert Permissions.match_shell_rule?("npm test", "npm test")
      refute Permissions.match_shell_rule?("npm test", "npm test --x")
      assert Permissions.match_shell_rule?("npm test:*", "npm test --coverage")
      assert Permissions.match_shell_rule?("npm test:*", "npm test")
      refute Permissions.match_shell_rule?("npm test:*", "npm testx")
    end

    test "wildcards: general, trailing-star-optional, escapes, dotAll" do
      assert Permissions.match_shell_rule?("git *", "git add .")
      assert Permissions.match_shell_rule?("git *", "git")
      refute Permissions.match_shell_rule?("* run *", "npm run")
      assert Permissions.match_shell_rule?("* run *", "npm run build")
      assert Permissions.match_shell_rule?("grep \\* *", "grep * file")
      refute Permissions.match_shell_rule?("grep \\* *", "grep x file")
      assert Permissions.match_shell_rule?("cat *", "cat <<EOF\nhello\nEOF")
    end

    test "split_compound is quote-aware" do
      assert Permissions.split_compound("cd x && rm -rf y") == ["cd x", "rm -rf y"]
      assert Permissions.split_compound("echo \"a && b\" && ls") == ["echo \"a && b\"", "ls"]
      assert Permissions.split_compound("a; b | c") == ["a", "b", "c"]
    end
  end

  describe "settings cascade + provenance" do
    test "deny beats allow, ask beats allow, provenance carried" do
      put_flag_permissions(%{
        "allow" => ["shell_execute(npm test:*)"],
        "deny" => ["shell_execute(rm:*)"],
        "ask" => ["shell_execute(git push:*)"]
      })

      assert Permissions.check("shell_execute", %{"command" => "npm test --watch"}) == :allow
      assert Permissions.check("shell_execute", %{"command" => "echo hi; rm -rf y"}) == :deny

      assert {:ask, %{rule: "shell_execute(git push:*)", source: :flag}} =
               Permissions.check_detailed("shell_execute", %{"command" => "git push origin x"})
    end

    test "compound commands: allow requires EVERY subcommand covered" do
      put_flag_permissions(%{"allow" => ["shell_execute(cd:*)", "shell_execute(ls)"]})

      assert Permissions.check("shell_execute", %{"command" => "cd x && ls"}) == :allow
      assert Permissions.check("shell_execute", %{"command" => "cd x && make"}) == :ask
    end

    test "MCP server rules (WS14 integration): mcp__server and mcp__server__*" do
      put_flag_permissions(%{"allow" => ["mcp__github"], "deny" => ["mcp__slack__*"]})

      assert Permissions.check("mcp__github__create_issue") == :allow
      assert Permissions.check("mcp__slack__post") == :deny
      assert Permissions.check("mcp__other__x") == :ask
    end

    test "file rules with CC alias + wildcard" do
      put_flag_permissions(%{"deny" => ["file_edit(.env)"], "allow" => ["Edit(lib/**)"]})

      assert Permissions.check("file_edit", %{"path" => ".env"}) == :deny
      assert Permissions.check("file_edit", %{"path" => "lib/foo/bar.ex"}) == :allow
      assert Permissions.check("file_edit", %{"path" => "config/x.exs"}) == :ask
    end
  end

  describe "legacy store migration" do
    test "old colon rules and bare tool rules still work, with :legacy provenance" do
      file = Application.get_env(:optimal_system_agent, :permissions_file)

      File.write!(
        file,
        Jason.encode!(%{"shell_execute:git *" => "allow", "file_write" => "deny"})
      )

      assert Permissions.check("shell_execute", %{"command" => "git status"}) == :allow

      assert {:deny, %{source: :legacy}} =
               Permissions.check_detailed("file_write", %{"path" => "a"})
    end
  end

  describe "bypass-immune safety paths + scope" do
    test "git internals, shell rc, OSA settings are flagged; normal paths are not" do
      assert is_binary(Permissions.bypass_immune_ask("file_edit", %{"path" => ".git/config"}))
      assert is_binary(Permissions.bypass_immune_ask("file_write", %{"path" => "~/.bashrc"}))

      assert is_binary(
               Permissions.bypass_immune_ask("file_write", %{
                 "path" => Path.expand("~/.osa/settings.json")
               })
             )

      assert Permissions.bypass_immune_ask("file_edit", %{"path" => "lib/a.ex"}) == nil
      assert Permissions.bypass_immune_ask("file_read", %{"path" => ".git/config"}) == nil
    end

    test "the subscription credential store always prompts on write, in every mode" do
      assert is_binary(
               Permissions.bypass_immune_ask("file_write", %{
                 "path" => Path.expand("~/.osa/subscriptions.json")
               })
             ),
             "rewriting this file swaps a paid account's token or redirects its pinned base_url; " <>
               "the agent has no legitimate reason to do either, so overdrive must not skip the prompt"
    end

    test "the subscription credential store is unreadable by the file tool" do
      assert ".osa/subscriptions.json" in OptimalSystemAgent.Tools.Builtins.FileRead.Constants.sensitive_paths(),
             "an agent that can read its own credential store is an exfiltration primitive"
    end

    test "out_of_scope_write flags foreign paths for mutating tools only" do
      assert Permissions.out_of_scope_write("file_write", %{"path" => "/etc/hosts"}) ==
               "/etc/hosts"

      assert Permissions.out_of_scope_write("file_write", %{"path" => "lib/a.ex"}) == nil
      assert Permissions.out_of_scope_write("file_read", %{"path" => "/etc/hosts"}) == nil
    end

    test "suggested_rule builds shell prefix rules" do
      assert Permissions.suggested_rule("shell_execute", %{"command" => "npm test --watch"}) ==
               "shell_execute(npm test:*)"

      assert Permissions.suggested_rule("file_write", %{"path" => "a.txt"}) == "file_write"
    end
  end
end
