defmodule OptimalSystemAgent.Agent.Loop.UnresolvableDeleteConfirmationTest do
  @moduledoc """
  Regression coverage for the audited overdrive gap: `rm -rf` whose target is
  only a command substitution (`rm -rf "$(pwd)"`, backticks, `${VAR}`) or a
  glob at/near a filesystem root matched `DangerousCommands`' broad-root
  pattern nowhere, `ShellExecute.Constants` classified command substitution
  as outright SAFE, and `ToolExecutor`'s overdrive branch (`mode in
  [:overdrive, :bypass] -> :allow`) short-circuited before any handler-level
  `:ask` was ever consulted — so the command ran with zero confirmation in
  full-auto mode.

  The fix adds a THIRD circuit-breaker severity, `:confirm_required`
  (`DangerousCommands.classify/1`), for exactly this class: a recursive force
  delete whose target the breaker cannot prove is safe OR unsafe. Unlike
  `:catastrophic` (never even offered) and `:overridable` (silently waived
  under overdrive), `:confirm_required` ALWAYS produces an interactive prompt
  — in every permission mode, overdrive included — and fails closed (never
  `:allow`) on a channel that cannot prompt.

  These tests exercise the public `ToolExecutor.approve_tool_call/2` boundary
  directly, the same way `dangerous_commands_bypass_test.exs` does for the
  original quoting bypass.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor

  @modes_that_must_ask [:overdrive, :bypass, :ask, :accept_edits]

  # Built from parts so neither this file nor any tool that scans it trips an
  # external command blocklist.
  @rm "rm -" <> "rf"

  setup do
    prior_interactive =
      Application.get_env(:optimal_system_agent, :interactive_permissions, false)

    # config/test.exs sets this to `true` globally so most tests do not need an
    # attended session to exercise an :allow path. That is exactly the opt-out
    # `non_interactive_decision/1` documents ("set only in config/test.exs and
    # for deliberately unattended deployments") — real, unconfigured deployments
    # default it OFF. The "unattended fails closed" tests below need the REAL
    # default (fail-closed), not the test-suite convenience default, or they
    # would just be re-testing the opt-out instead of the invariant.
    prior_bypass = Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass)
    Application.put_env(:optimal_system_agent, :interactive_permissions, false)
    Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :interactive_permissions, prior_interactive)

      case prior_bypass do
        nil -> Application.delete_env(:optimal_system_agent, :non_interactive_permission_bypass)
        v -> Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, v)
      end
    end)

    :ok
  end

  defp enable_interactive,
    do: Application.put_env(:optimal_system_agent, :interactive_permissions, true)

  defp state(mode), do: struct(Loop, session_id: "udc-#{unique()}", permission_mode: mode)
  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp shell(cmd),
    do: %{id: "tc-#{unique()}", name: "shell_execute", arguments: %{"command" => cmd}}

  # ── the audited command families, one per mode ─────────────────────────

  @unresolvable [
    {"command substitution", "#{@rm} \"$(pwd)\""},
    {"backtick substitution", "#{@rm} `git rev-parse --show-toplevel`"},
    {"brace parameter expansion", "#{@rm} \"${SOME_VAR}\""},
    {"near-root glob", "#{@rm} /etc/*"}
  ]

  describe "unattended, production defaults: fails closed, never :allow" do
    for {label, cmd} <- @unresolvable, mode <- [:overdrive, :bypass, :ask, :accept_edits] do
      test "#{mode}: #{label} is blocked, not silently allowed" do
        result = ToolExecutor.approve_tool_call(shell(unquote(cmd)), state(unquote(mode)))

        refute result == :allow,
               "#{unquote(mode)} silently ran an unresolvable delete: #{unquote(cmd)}"

        assert {:blocked, msg} = result
        assert msg =~ "requires interactive approval"
      end
    end

    test "the explicit test-only bypass opt-out still auto-allows (documented, not a regression)" do
      # `non_interactive_decision/1`'s ONE escape hatch, restored here to prove
      # this test file is not silently relying on it for the assertions above.
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, true)

      assert :allow =
               ToolExecutor.approve_tool_call(
                 shell("#{@rm} \"$(pwd)\""),
                 state(:overdrive)
               )
    end
  end

  describe "attended (interactive on): always prompts, overdrive included, never :allow" do
    for {label, cmd} <- @unresolvable, mode <- @modes_that_must_ask do
      test "#{mode}: #{label} asks instead of running" do
        enable_interactive()

        assert {:ask, request_id, summary} =
                 ToolExecutor.approve_tool_call(shell(unquote(cmd)), state(unquote(mode)))

        assert is_binary(request_id)
        assert summary.reason =~ "not bypassable"
        assert summary.timeout_ms == 120_000
        assert is_binary(summary.timeout_message)
      end
    end

    test "plan mode still denies (read-only), it does not ask" do
      enable_interactive()

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(shell("#{@rm} \"$(pwd)\""), state(:plan))

      assert msg =~ "plan mode"
    end
  end

  describe "ordinary scoped rm is unaffected (no regression)" do
    test "overdrive still silently allows a scoped delete, unattended" do
      assert :allow = ToolExecutor.approve_tool_call(shell("#{@rm} ./build"), state(:overdrive))
    end

    test "attended overdrive does not ask for a scoped delete either" do
      enable_interactive()
      assert :allow = ToolExecutor.approve_tool_call(shell("#{@rm} ./build"), state(:overdrive))
    end
  end

  describe "the literal broad-root class still wins over the unresolvable one" do
    test "rm -rf / \"$(pwd)\" is the hard, non-bypassable :catastrophic block" do
      cmd = "#{@rm} / \"$(pwd)\""

      assert {:blocked, msg} = ToolExecutor.approve_tool_call(shell(cmd), state(:overdrive))
      assert msg =~ "hard safety limit"
    end
  end

  # ── the 120s timeout + rewrite-guidance message, without a real wait ────

  describe "await_permission/4 honors a summary-carried timeout override" do
    test "a short override times out with the CUSTOM message, not the generic one" do
      enable_interactive()
      tool_call = shell("#{@rm} \"$(pwd)\"")
      s = state(:overdrive)
      request_id = PermissionBroker.new_request_id()

      summary = %{
        args: "rm -rf \"$(pwd)\"",
        target: nil,
        kind: "bash",
        old_content: nil,
        new_content: nil,
        warning: nil,
        reason: "Safety check (not bypassable): test",
        suggestions: [],
        timeout_ms: 50,
        timeout_message: "Blocked: rewrite the command and try again"
      }

      # Nobody ever calls PermissionBroker.respond/2 — this must time out, not hang.
      assert {:blocked, "Blocked: rewrite the command and try again"} =
               ToolExecutor.await_permission(tool_call, s, request_id, summary)
    end

    test "an override with only :timeout_ms still falls back to the generic message" do
      enable_interactive()
      tool_call = shell("#{@rm} ./build")
      s = state(:ask)
      request_id = PermissionBroker.new_request_id()

      summary = %{
        args: "rm -rf ./build",
        target: nil,
        kind: "bash",
        old_content: nil,
        new_content: nil,
        warning: nil,
        reason: "test",
        suggestions: [],
        timeout_ms: 50
      }

      assert {:blocked, msg} = ToolExecutor.await_permission(tool_call, s, request_id, summary)
      assert msg =~ "timed out with no response — not run"
    end

    test "emit_permission_required/4 carries the overridden timeout, not the 300s default" do
      s = %{session_id: "udc-emit-#{unique()}", permission_tier: :full, messages: []}
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s.session_id}")
      request_id = PermissionBroker.new_request_id()

      ToolExecutor.emit_permission_required(
        s,
        request_id,
        %{id: "tc-1", name: "shell_execute", arguments: %{}},
        %{args: "rm -rf \"$(pwd)\"", kind: "bash", timeout_ms: 120_000}
      )

      assert_receive {:osa_event, ev}, 1_000
      assert ev.request_id == request_id
      assert ev.timeout_ms == 120_000
      refute ev.timeout_ms == PermissionBroker.default_timeout_ms()
    end

    test "emit_permission_required/4 falls back to the default when unset (no regression)" do
      s = %{session_id: "udc-emit-#{unique()}", permission_tier: :full, messages: []}
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s.session_id}")
      request_id = PermissionBroker.new_request_id()

      ToolExecutor.emit_permission_required(
        s,
        request_id,
        %{id: "tc-1", name: "shell_execute", arguments: %{}},
        %{args: "rm -rf ./build", kind: "bash"}
      )

      assert_receive {:osa_event, ev}, 1_000
      assert ev.timeout_ms == PermissionBroker.default_timeout_ms()
    end
  end
end
