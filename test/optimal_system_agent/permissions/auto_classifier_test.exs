defmodule OptimalSystemAgent.Permissions.AutoClassifierTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Permissions.AutoClassifier

  defp shell(cmd), do: %{name: "shell_execute", arguments: %{"command" => cmd}}

  # A state whose LLM stage always blocks — so an :inconclusive fast-path result
  # is deterministically :ask (proves the fast-path itself did NOT auto-allow,
  # without depending on a live provider / use_llm config).
  defp blocking, do: %{auto_classifier_fn: fn _n, _a -> :block end}

  # Enable the classifier via config for the duration of a test, restoring the
  # previous value afterwards. async: false because this mutates app env.
  defp with_enabled(opts, fun) do
    prev = Application.get_env(:optimal_system_agent, :auto_mode, [])
    auto_allow = Keyword.merge([enabled: true, use_llm: false], opts)
    Application.put_env(:optimal_system_agent, :auto_mode, Keyword.put(prev, :auto_allow, auto_allow))

    try do
      fun.()
    after
      Application.put_env(:optimal_system_agent, :auto_mode, prev)
    end
  end

  describe "enabled?/1" do
    test "defaults to false — permission flow unchanged" do
      refute AutoClassifier.enabled?(%{})
    end

    test "honors a per-state override" do
      assert AutoClassifier.enabled?(%{auto_permission: true})
      refute AutoClassifier.enabled?(%{auto_permission: false})
    end
  end

  describe "fast-path (no LLM)" do
    test "allows a read-only pipeline" do
      assert AutoClassifier.classify(shell("cat foo.txt | grep bar | sort | uniq")) == :allow
      assert AutoClassifier.classify(shell("ls -la && git status")) == :allow
      assert AutoClassifier.classify(shell("rg --files | wc -l")) == :allow
      assert AutoClassifier.classify(shell("git diff HEAD~1")) == :allow
    end

    test "does NOT allow a write / rm (defers, never auto-allows)" do
      # A blocking LLM stage ⇒ an :inconclusive fast-path deterministically :ask.
      assert AutoClassifier.classify(shell("rm -rf build"), blocking()) == :ask
      assert AutoClassifier.classify(shell("echo hi > /etc/motd"), blocking()) == :ask
      assert AutoClassifier.classify(shell("cat x > out.txt"), blocking()) == :ask
      assert AutoClassifier.classify(shell("git push origin main"), blocking()) == :ask
      assert AutoClassifier.classify(shell("sed -i s/a/b/ file"), blocking()) == :ask
    end

    test "command substitution / a mutating find is never fast-allowed" do
      assert AutoClassifier.classify(shell("cat $(rm -rf x)"), blocking()) == :ask
      assert AutoClassifier.classify(shell("find . -delete"), blocking()) == :ask
      assert AutoClassifier.classify(shell("find . -exec rm {} \\;"), blocking()) == :ask
    end

    test "a chain with any non-read-only segment defers" do
      assert AutoClassifier.classify(shell("ls && rm foo"), blocking()) == :ask
      assert AutoClassifier.classify(shell("git status && git commit -m x"), blocking()) == :ask
    end
  end

  describe "LLM stage via injected assessor" do
    test "an :allow verdict downgrades an inconclusive call" do
      state = %{auto_classifier_fn: fn _n, _a -> :allow end}
      assert AutoClassifier.classify(shell("rm -rf build"), state) == :allow
    end

    test "a :block verdict keeps the ask (fail-safe)" do
      state = %{auto_classifier_fn: fn _n, _a -> :block end}
      assert AutoClassifier.classify(shell("rm -rf build"), state) == :ask
    end

    test "provably-safe reads never reach the assessor" do
      state = %{auto_classifier_fn: fn _n, _a -> flunk("assessor must not be called") end}
      assert AutoClassifier.classify(shell("ls -la"), state) == :allow
    end
  end

  describe "parse_verdict/1 (fail-safe)" do
    test "strict JSON allow/block" do
      assert AutoClassifier.parse_verdict(~s({"allow": true})) == :allow
      assert AutoClassifier.parse_verdict(~s({"allow": false})) == :block
      assert AutoClassifier.parse_verdict(~s({"shouldBlock": true})) == :block
      assert AutoClassifier.parse_verdict(~s({"shouldBlock": false})) == :allow
    end

    test "one-word replies" do
      assert AutoClassifier.parse_verdict("allow") == :allow
      assert AutoClassifier.parse_verdict("BLOCK") == :block
    end

    test "ambiguous / empty text is unavailable (⇒ prompt)" do
      assert AutoClassifier.parse_verdict("") == :unavailable
      assert AutoClassifier.parse_verdict("I think this is probably fine but...") == :unavailable
    end
  end

  describe "maybe_allow/2 — the downgrade entry point" do
    test "returns :ask verbatim when disabled (default)" do
      assert AutoClassifier.maybe_allow(shell("ls -la"), %{}) == :ask
    end

    test "downgrades a provably-safe read when enabled" do
      with_enabled([], fn ->
        assert AutoClassifier.maybe_allow(shell("ls -la"), %{}) == :allow
      end)
    end

    test "keeps the ask for a write when enabled and LLM is off" do
      with_enabled([], fn ->
        assert AutoClassifier.maybe_allow(shell("rm -rf build"), %{}) == :ask
      end)
    end

    test "an assessor :block keeps the ask even when enabled" do
      with_enabled([], fn ->
        state = %{auto_classifier_fn: fn _n, _a -> :block end}
        assert AutoClassifier.maybe_allow(shell("rm -rf build"), state) == :ask
      end)
    end
  end

  # ── integration: the single wiring point in ToolExecutor.approve_tool_call ──
  describe "ToolExecutor.approve_tool_call/2 integration" do
    setup do
      # The default-ask downgrade branch is only reachable with interactive
      # prompts ON; the test env defaults them OFF (fail-closed).
      prior_int = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
      Application.put_env(:optimal_system_agent, :interactive_permissions, true)

      file = Application.get_env(:optimal_system_agent, :permissions_file)
      if is_binary(file), do: File.rm(file)

      on_exit(fn ->
        Application.put_env(:optimal_system_agent, :interactive_permissions, prior_int)
        if is_binary(file), do: File.rm(file)
      end)

      :ok
    end

    defp loop_state(overrides \\ []) do
      struct(
        Loop,
        [session_id: "auto-#{System.unique_integer([:positive])}", permission_mode: :ask, permission_tier: :full] ++
          overrides
      )
    end

    defp scall(cmd), do: %{id: "tc-#{System.unique_integer([:positive])}", name: "shell_execute", arguments: %{"command" => cmd}}

    test "auto-mode OFF → a default ask is unchanged" do
      # Classifier disabled (default): a shell read still prompts.
      assert {:ask, _rid, _summary} = ToolExecutor.approve_tool_call(scall("ls -la"), loop_state())
    end

    test "auto-mode ON → a provably-safe read is downgraded to :allow" do
      with_enabled([], fn ->
        assert :allow = ToolExecutor.approve_tool_call(scall("ls -la && git status"), loop_state())
      end)
    end

    test "auto-mode ON → a write still prompts (fast-path defers, LLM off)" do
      with_enabled([], fn ->
        assert {:ask, _rid, _summary} =
                 ToolExecutor.approve_tool_call(scall("cp a b && rm -rf ./build"), loop_state())
      end)
    end

    test "catastrophic stays hard-denied regardless of auto-mode" do
      with_enabled([], fn ->
        assert {:blocked, msg} = ToolExecutor.approve_tool_call(scall("rm -rf /"), loop_state())
        assert msg =~ "hard safety limit" or msg =~ "unrecoverable"
      end)
    end

    test "the classifier can never upgrade a saved deny rule" do
      Permissions.save_rule("shell_execute(rm:*)", :deny_always)

      with_enabled([], fn ->
        assert {:blocked, msg} = ToolExecutor.approve_tool_call(scall("rm foo.txt"), loop_state())
        assert msg =~ "denied"
      end)
    end
  end
end
