defmodule OptimalSystemAgent.CLI.Headless.OptionsTest do
  @moduledoc """
  `osa run` flag parsing: the exact argv MIOSA's runner sends, Claude Code and
  Codex spellings, and every usage error that must exit 2 before OSA boots.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.CLI.Headless.Options

  defp parse!(argv) do
    assert {:ok, opts} = Options.parse(argv)
    opts
  end

  describe "the MIOSA runner contract" do
    test "osa run --format stream-json [--model M] [--overdrive] [--resume ID]" do
      opts =
        parse!(~w(--format stream-json --model gpt-6 --overdrive --resume headless-1-abc))

      assert opts.format == "stream-json"
      assert opts.model == "gpt-6"
      assert opts.permission_mode == :overdrive
      assert opts.resume == "headless-1-abc"
      assert opts.prompt == nil
      assert opts.input_format == "text"
    end

    test "defaults: text output, no permission mode, fresh session" do
      opts = parse!([])
      assert opts.format == "text"
      assert opts.permission_mode == nil
      assert opts.resume == nil and opts.session_id == nil and opts.continue == false
    end

    test "trailing words are the prompt" do
      assert parse!(~w(--model m fix the build)).prompt == "fix the build"
    end
  end

  describe "Claude Code and Codex spellings" do
    test "overdrive aliases" do
      for flag <- ~w(--overdrive --dangerously-skip-permissions --yolo) do
        assert parse!([flag]).permission_mode == :overdrive
      end
    end

    test "permission modes, OSA and Claude names" do
      assert parse!(~w(--permission-mode plan)).permission_mode == :plan
      assert parse!(~w(--permission-mode acceptEdits)).permission_mode == :accept_edits
      assert parse!(~w(--permission-mode auto-edit)).permission_mode == :accept_edits
      assert parse!(~w(--permission-mode bypassPermissions)).permission_mode == :overdrive
      assert parse!(~w(--permission-mode default)).permission_mode == :ask
    end

    test "-p is accepted and ignored, --output-format is --format" do
      opts = parse!(~w(-p --output-format json hello))
      assert opts.format == "json"
      assert opts.prompt == "hello"
    end

    test "session flags" do
      assert parse!(~w(-r abc)).resume == "abc"
      assert parse!(~w(-c)).continue

      assert parse!(~w(--session-id 6f1c2b8e-1d2a-4c3b-9e8f-0a1b2c3d4e5f)).session_id ==
               "6f1c2b8e-1d2a-4c3b-9e8f-0a1b2c3d4e5f"
    end

    test "cwd: --cwd, Codex's --cd and -C" do
      for argv <- [~w(--cwd /tmp), ~w(--cd /tmp), ~w(-C /tmp)] do
        assert parse!(argv).cwd == "/tmp"
      end
    end

    test "tool lists: Claude names map to OSA tools, rules keep their content" do
      opts =
        parse!([
          "--tools",
          "Bash,Read",
          "--allowedTools",
          "Bash(git status:*) file_read",
          "--disallowed-tools",
          "WebFetch"
        ])

      assert opts.tools == ["shell_execute", "file_read"]
      assert opts.allowed_rules == ["Bash(git status:*)", "file_read"]
      assert opts.disallowed_rules == ["WebFetch"]
    end

    test "rules split on commas and spaces but not inside parentheses" do
      assert Options.split_rules("shell_execute(npm run test, lint),file_read  Edit") ==
               ["shell_execute(npm run test, lint)", "file_read", "Edit"]
    end

    test "repeatable --mcp-config, --strict-mcp-config, limits and prompts" do
      opts =
        parse!(
          ~w(--mcp-config a.json --mcp-config b.json --strict-mcp-config --max-turns 7 --max-budget 2.5) ++
            ["--append-system-prompt", "Be terse.", "--system-prompt", "You are a test."]
        )

      assert opts.mcp_configs == ["a.json", "b.json"]
      assert opts.strict_mcp_config
      assert opts.max_turns == 7
      assert opts.max_budget_usd == 2.5
      assert opts.append_system_prompt == "Be terse."
      assert opts.system_prompt == "You are a test."
    end

    test "Claude's --add-dir and Codex's -o" do
      opts = parse!(~w(--add-dir /data --add-dir /cache -o last.txt))
      assert opts.add_dirs == ["/data", "/cache"]
      assert opts.output_last_message == "last.txt"
    end

    @tag :tmp_dir
    test "prompt files", %{tmp_dir: dir} do
      path = Path.join(dir, "append.md")
      File.write!(path, "From a file.")
      assert parse!(["--append-system-prompt-file", path]).append_system_prompt == "From a file."
    end
  end

  describe "usage errors" do
    for {argv, fragment} <- [
          {~w(--format yaml), "unknown --format"},
          {~w(--input-format xml), "unknown --input-format"},
          {~w(--input-format stream-json), "needs --format stream-json"},
          {~w(--input-format stream-json --format stream-json hi), "on stdin"},
          {~w(--resume a --continue), "mutually exclusive"},
          {~w(--resume a --session-id b), "mutually exclusive"},
          {~w(--resume ../../etc/passwd), "invalid --resume"},
          {~w(--session-id a.b), "invalid --session-id"},
          {~w(--max-turns 0), "--max-turns"},
          {~w(--max-budget -1), "--max-budget"},
          {~w(--permission-mode sometimes), "unknown --permission-mode"},
          {~w(--permission-mode plan --overdrive), "conflicts"},
          {~w(--verbose --quiet), "cannot both"},
          {~w(--no-such-flag), "unknown option"},
          {~w(--append-system-prompt x --append-system-prompt-file y), "cannot both"}
        ] do
      test "#{Enum.join(argv, " ")}" do
        assert {:error, message} = Options.parse(unquote(argv))
        assert message =~ unquote(fragment)
      end
    end

    test "session ids are filename-safe exactly as MIOSA checks them" do
      assert Regex.match?(Options.session_id_format(), "headless-1791507141836-3b0c0342065c")
      assert Regex.match?(Options.session_id_format(), "6f1c2b8e-1d2a-4c3b-9e8f-0a1b2c3d4e5f")
      refute Regex.match?(Options.session_id_format(), "-leading-dash")
      refute Regex.match?(Options.session_id_format(), "has space")
      refute Regex.match?(Options.session_id_format(), String.duplicate("a", 129))
    end
  end
end
