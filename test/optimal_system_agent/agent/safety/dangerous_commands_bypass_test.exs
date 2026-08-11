defmodule OptimalSystemAgent.Agent.Safety.DangerousCommandsBypassTest do
  @moduledoc """
  Regression coverage for the circuit-breaker QUOTING/WRAPPER bypass.

  The breaker used to match the raw, pre-shell command string while the kernel
  runs the post-shell one. Only the bare form was caught:

      rm -rf /            → blocked
      rm -rf "/"          → PASSED
      rm -rf '/'          → PASSED
      "rm" -rf /          → PASSED
      rm -rf ~ (quoted)   → PASSED
      rm -rf \\/           → PASSED
      bash -c "rm -rf /"  → PASSED (and also evaded the :ask tier — head `bash`)

  Every one of those executes identically to the blocked form. Because the hole
  was in the MATCHER and not in the gating, it defeated every permission mode,
  `:overdrive` included — where nothing else stands between a main-tier agent
  and the command.

  The tests below are deliberately table-driven and parameterised over
  quoting × wrapper so that a future regex-only "fix" that stops normalizing
  fails here loudly instead of silently reopening the hole.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Safety.CommandVariants
  alias OptimalSystemAgent.Agent.Safety.DangerousCommands, as: DC
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler

  # Built from parts so neither this file nor any tool that scans it trips an
  # external command blocklist.
  @rm "rm -" <> "rf"
  @root "/"

  # Every permission mode the executor knows. The breaker is clause 1 of
  # `approve_tool_call/2` and must hold in ALL of them — `:overdrive` is named
  # explicitly because it is the mode the operator actually runs in, and the
  # mode in which no other gate applies to a main-tier agent.
  @modes [:overdrive, :bypass, :ask, :plan, :accept_edits]

  setup do
    prior = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
    Application.put_env(:optimal_system_agent, :interactive_permissions, false)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :interactive_permissions, prior) end)
    :ok
  end

  defp state(mode), do: struct(Loop, session_id: "cb-#{unique()}", permission_mode: mode)
  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp shell(cmd),
    do: %{id: "tc-#{unique()}", name: "shell_execute", arguments: %{"command" => cmd}}

  defp classify(cmd), do: Handler.check_permissions(%{"command" => cmd}, %{})

  # ── the parameterised dangerous matrix ────────────────────────────────
  #
  # quoting × wrapper. Each cell is a DIFFERENT spelling of the SAME kernel-level
  # operation, so every cell must produce the same verdict: blocked.

  # A quoting style applied to the target argument (and, for :cmd_quoted, to the
  # command name itself).
  defp quote_target(:bare, t), do: t
  defp quote_target(:double, t), do: "\"" <> t <> "\""
  defp quote_target(:single, t), do: "'" <> t <> "'"
  defp quote_target(:backslash, t), do: String.replace(t, "/", "\\/")

  defp spell(:bare_cmd, style, target), do: "#{@rm} #{quote_target(style, target)}"
  defp spell(:quoted_cmd, style, target), do: "\"rm\" -rf #{quote_target(style, target)}"

  defp wrap(:bare, inner), do: inner
  defp wrap(:bash_c, inner), do: "bash -c \"#{inner}\""
  defp wrap(:sh_c, inner), do: "sh -c '#{inner}'"
  defp wrap(:bash_lc, inner), do: "bash -lc \"#{inner}\""
  defp wrap(:sudo, inner), do: "sudo #{inner}"
  defp wrap(:env, inner), do: "env FOO=bar #{inner}"
  defp wrap(:timeout, inner), do: "timeout 30 #{inner}"
  defp wrap(:nohup, inner), do: "nohup #{inner}"
  defp wrap(:nested, inner), do: "bash -c \"sudo #{inner}\""

  @quotings [:bare, :double, :single, :backslash]
  @spellings [:bare_cmd, :quoted_cmd]
  @wrappers [:bare, :bash_c, :sh_c, :bash_lc, :sudo, :env, :timeout, :nohup, :nested]

  # `sh -c '…'` / nested `'…'` cannot carry a single-quoted payload without
  # shell-level escaping, so that combination is not a real spelling.
  defp buildable?(wrapper, quoting) do
    not (wrapper in [:sh_c] and quoting == :single)
  end

  defp dangerous_matrix do
    for w <- @wrappers,
        q <- @quotings,
        s <- @spellings,
        buildable?(w, q),
        target <- [@root, "~"],
        # `~` has no `/` for the backslash style to escape — it would be a
        # duplicate of :bare rather than a distinct spelling.
        not (target == "~" and q == :backslash) do
      {"#{w}/#{q}/#{s}/#{target}", wrap(w, spell(s, q, target))}
    end
  end

  describe "quoting and wrapper variants of rm -rf <root> are blocked" do
    test "every cell of the quoting x wrapper matrix is blocked by check_command/1" do
      failures =
        for {label, cmd} <- dangerous_matrix(),
            DC.check_command(cmd) == :ok,
            do: {label, cmd}

      assert failures == [], """
      These spellings of a root recursive-force delete were NOT blocked.
      Each executes identically to the bare form:

      #{Enum.map_join(failures, "\n", fn {l, c} -> "  #{l}: #{inspect(c)}" end)}
      """
    end

    test "every cell is hard-denied by the shell_execute permission tier too" do
      failures =
        for {label, cmd} <- dangerous_matrix(),
            not match?({:deny, _}, classify(cmd)),
            do: {label, cmd, classify(cmd)}

      assert failures == [], """
      These spellings were not hard-denied by shell_execute:

      #{Enum.map_join(failures, "\n", fn {l, c, v} -> "  #{l}: #{inspect(c)} → #{inspect(v)}" end)}
      """
    end
  end

  # ── the specific reported bypasses, spelled out one by one ────────────

  describe "the reported bypasses" do
    for {label, cmd} <- [
          {"bare (was already blocked)", "rm -" <> "rf /"},
          {"double-quoted target", "rm -" <> "rf \"/\""},
          {"single-quoted target", "rm -" <> "rf '/'"},
          {"quoted command name", "\"rm\" -" <> "rf /"},
          {"quoted tilde", "rm -" <> "rf \"~\""},
          {"backslash-escaped root", "rm -" <> "rf \\/"},
          {"bash -c wrapper", "bash -c \"rm -" <> "rf /\""},
          {"sh -c wrapper", "sh -c 'rm -" <> "rf /'"},
          {"bash -lc + sudo + quoting", "bash -lc \"sudo rm -" <> "rf '/'\""},
          {"nested bash -c", "bash -c \"bash -c \\\"rm -" <> "rf /\\\"\""},
          {"env prefix", "env FOO=1 rm -" <> "rf '/'"},
          {"timeout prefix", "timeout 5 rm -" <> "rf \"/\""},
          {"xargs", "xargs -0 rm -" <> "rf /"},
          {"find -exec", "find . -exec rm -" <> "rf '/' \\;"},
          {"python -c", "python3 -c 'import os; os.system(\"rm -" <> "rf /\")'"},
          {"node -e", "node -e 'require(\"child_process\").exec(\"rm -" <> "rf ~\")'"}
        ] do
      test "blocked: #{label}" do
        assert {:blocked, _} = DC.check_command(unquote(cmd))
      end

      for mode <- @modes do
        test "blocked in #{mode} mode: #{label}" do
          assert {:blocked, msg} =
                   ToolExecutor.approve_tool_call(shell(unquote(cmd)), state(unquote(mode)))

          assert msg =~ "hard safety limit"
        end
      end
    end
  end

  # ── the :ask-tier evasion (second, independent bypass) ────────────────

  describe "wrapper payloads are visible to the :ask tier" do
    for {label, cmd} <- [
          {"bash -c", "bash -c \"rm -" <> "rf ./build\""},
          {"sh -c", "sh -c 'rm -" <> "rf ./build'"},
          {"bash -lc + sudo", "bash -lc \"sudo rm -" <> "rf ./build\""},
          {"timeout", "timeout 60 rm -" <> "rf ./build"},
          # NB: `find .` (a bare `.` argument) is a broad root in its own right
          # and is hard-denied — pre-existing behaviour, unrelated to wrappers.
          {"find -exec", "find ./src -name '*.o' -exec rm -" <> "rf {} \\;"}
        ] do
      test "asks (not silently allowed): #{label}" do
        # Before the fix the only visible command head was the wrapper (`bash`,
        # `timeout`, `find`) — none of them risky — so a scoped `rm` inside a
        # wrapper was auto-ALLOWED with no prompt at all.
        assert {:ask, reason} = classify(unquote(cmd))
        assert is_binary(reason)
      end
    end
  end

  # ── negatives: the breaker must not block legitimate work ─────────────
  #
  # A breaker that blocks real work gets switched off by its users, which is its
  # own security failure. These must stay allowed in every spelling.

  @negatives [
    {"scoped relative", "rm -" <> "rf ./build"},
    {"scoped absolute", "rm -" <> "rf /home/x/tmp"},
    {"node_modules", "rm -" <> "rf node_modules"},
    {"deep scoped path", "rm -" <> "rf /home/x/project/tmp/cache"},
    {"a file", "rm build/output.o"},
    {"listing", "ls -la"},
    {"echo", "echo hello"},
    {"normal push", "git push origin main"},
    {"curl into jq", "curl https://api.example.com/x | jq ."},
    {"reading /etc", "cat /etc/os-release"},
    {"cd and list", "cd /tmp && ls"},
    {"pipeline", "ps aux | grep beam"},
    {"command substitution", "echo $(git rev-parse HEAD)"},
    {"export", "export FOO=bar; echo $FOO"}
  ]

  describe "scoped and benign commands still pass" do
    for {label, cmd} <- @negatives do
      test "check_command/1 allows: #{label}" do
        assert DC.check_command(unquote(cmd)) == :ok
      end
    end

    test "quoted and wrapped SCOPED deletes are not blocked either" do
      scoped = "./build"

      cmds =
        for w <- @wrappers,
            q <- [:bare, :double, :single],
            buildable?(w, q),
            do: wrap(w, "#{@rm} #{quote_target(q, scoped)}")

      blocked = for c <- cmds, match?({:blocked, _}, DC.check_command(c)), do: c

      assert blocked == [], """
      Normalization over-matched — these SCOPED deletes were blocked:

      #{Enum.map_join(blocked, "\n", &("  " <> inspect(&1)))}
      """
    end

    for {label, cmd} <- @negatives do
      test "overdrive still allows: #{label}" do
        assert :allow = ToolExecutor.approve_tool_call(shell(unquote(cmd)), state(:overdrive))
      end
    end
  end

  # ── one blocklist, not two ────────────────────────────────────────────

  describe "the two blocklists have been collapsed into one" do
    test "shell_execute no longer carries its own rm/fork-bomb/dd rules" do
      # These classes are owned solely by DangerousCommands, matched over the
      # normalized variant set. A duplicate here is how the quoting hole was
      # fixed in one list and left open in the other.
      sources = Enum.map(Constants.catastrophic_patterns(), &Regex.source/1)

      assert Enum.reject(sources, &(not (&1 =~ "rm"))) == [],
             "shell_execute must not keep a second rm -rf blocklist: #{inspect(sources)}"

      assert Enum.reject(sources, &(not (&1 =~ "of=" or &1 =~ ":\\s*\\("))) == [],
             "shell_execute must not keep a second dd/fork-bomb blocklist: #{inspect(sources)}"
    end

    test "the breaker and the shell hard-deny tier agree on every dangerous cell" do
      disagreements =
        for {label, cmd} <- dangerous_matrix(),
            breaker = match?({:blocked, _}, DC.check_command(cmd)),
            tier = match?({:deny, _}, classify(cmd)),
            breaker != tier,
            do: {label, cmd, breaker, tier}

      assert disagreements == [],
             "breaker and shell hard-deny tier disagree: #{inspect(disagreements)}"
    end

    test "the breaker and the shell hard-deny tier agree on every negative" do
      disagreements =
        for {label, cmd} <- @negatives,
            breaker = match?({:blocked, _}, DC.check_command(cmd)),
            tier = match?({:deny, _}, classify(cmd)),
            breaker != tier,
            do: {label, cmd, breaker, tier}

      assert disagreements == [],
             "breaker and shell hard-deny tier disagree: #{inspect(disagreements)}"
    end
  end

  # ── the normalizer itself ─────────────────────────────────────────────

  describe "CommandVariants" do
    test "the raw command is always the first variant" do
      assert ["ls -la" | _] = CommandVariants.variants("ls -la")
    end

    test "unquoting resolves quotes anywhere in a token, not just outermost" do
      assert CommandVariants.shell_unquote("\"/\"") == "/"
      assert CommandVariants.shell_unquote("'~'") == "~"
      assert CommandVariants.shell_unquote("\\/") == "/"
      assert CommandVariants.shell_unquote("a\"b\"c") == "abc"
      assert CommandVariants.shell_unquote("/tmp/x") == "/tmp/x"
    end

    test "wrapper payloads are extracted recursively" do
      vs = CommandVariants.variants("bash -lc \"sudo #{@rm} '#{@root}'\"")
      assert "#{@rm} #{@root}" in vs
    end

    test "recursion is bounded and the set stays small" do
      nested = Enum.reduce(1..40, "#{@rm} #{@root}", fn _, acc -> "bash -c \"#{acc}\"" end)
      vs = CommandVariants.variants(nested)
      assert length(vs) <= 64
    end

    test "an oversized command still contains the raw input among its variants" do
      big = String.duplicate("x", 30_000)
      vs = CommandVariants.variants(big)

      assert big in vs

      assert {:blocked, _} =
               DC.check_command(String.duplicate("# pad\n", 10) <> "#{@rm} #{@root}")
    end

    # The size bound used to fail OPEN: over @max_length, `variants/1` returned
    # the raw, still-quoted string and nothing else, so 20 KB of padding was a
    # complete bypass of the hard-deny tier. A bound on a safety analysis has to
    # fail closed instead.
    test "padding a catastrophic command past the size bound does not bypass the breaker" do
      pad = String.duplicate("#", 25_000)

      for cmd <- [
            ~s(#{@rm} "#{@root}" ; echo #{pad}),
            ~s(bash -c "#{@rm} '#{@root}'" # #{pad})
          ] do
        assert byte_size(cmd) > 20_000
        assert {:blocked, _} = DC.check_command(cmd), "not blocked: #{String.slice(cmd, 0, 60)}"
        assert DC.catastrophic_destruction?(cmd)
      end
    end

    test "an incompletely-analysed command reports itself as such" do
      assert CommandVariants.fully_analyzed?("ls -la")
      refute CommandVariants.fully_analyzed?(String.duplicate("x", 30_000))
      refute CommandVariants.fully_analyzed?(nil)
    end

    test "malformed input never raises" do
      for cmd <- ["\"unterminated", "'", "\\", "$(", "${", "`", ""] do
        assert is_list(CommandVariants.variants(cmd))
        assert DC.check_command(cmd) in [:ok] or match?({:blocked, _}, DC.check_command(cmd))
      end
    end

    test "non-binaries are handled" do
      assert CommandVariants.variants(nil) == []
      assert CommandVariants.variants(42) == []
    end
  end

  # ── the tool-call boundary, in overdrive ──────────────────────────────

  describe "tool-call dispatch under overdrive" do
    test "a quoted root delete routed through an MCP shell server is blocked" do
      call = %{
        id: "tc-#{unique()}",
        name: "mcp__desktop__execute_command",
        arguments: %{"command" => "bash -c \"#{@rm} '#{@root}'\""}
      }

      assert {:blocked, msg} = ToolExecutor.approve_tool_call(call, state(:overdrive))
      assert msg =~ "hard safety limit"
    end

    test "a quoted root path passed to file_delete is blocked" do
      call = %{id: "tc-#{unique()}", name: "file_delete", arguments: %{"path" => "\"/\""}}
      assert {:blocked, _} = ToolExecutor.approve_tool_call(call, state(:overdrive))
    end
  end
end
