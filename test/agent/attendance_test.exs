defmodule OptimalSystemAgent.Agent.AttendanceTest do
  @moduledoc """
  OSA could not distinguish an attended session from an unattended one.

  Two unconnected mechanisms existed: `state.channel` (never consulted for this
  purpose) and an app-env flag `:interactive_permissions` duplicated verbatim in
  three modules, defaulting to `true`, and never set by anything headless. So
  `mix osa.run` — `channel: :headless`, flag untouched — took the INTERACTIVE
  branch and could park on `PermissionBroker.await/3` for its full 300-second
  ceiling per prompt, with nobody attached to answer, repeatedly.

  These tests pin the single derived answer, and — the requirement that matters
  most — that "unattended" resolves to FAIL CLOSED and never to self-approval.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Attendance
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.Survey

  setup do
    prior = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
    prior_env = System.get_env("OSA_ATTENDED")

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :interactive_permissions, prior)

      if prior_env,
        do: System.put_env("OSA_ATTENDED", prior_env),
        else: System.delete_env("OSA_ATTENDED")
    end)

    # config/test.exs disables interactive permissions globally, which is a hard
    # veto. Lift it so the CHANNEL derivation is what these tests observe.
    Application.put_env(:optimal_system_agent, :interactive_permissions, true)
    System.delete_env("OSA_ATTENDED")

    sid = "attend_#{System.unique_integer([:positive])}"
    on_exit(fn -> Attendance.clear(sid) end)
    {:ok, sid: sid}
  end

  describe "derived from the channel" do
    test "headless and scheduler sessions are unattended", %{sid: sid} do
      Attendance.put_channel(sid, :headless)
      refute Attendance.attended?(sid)

      Attendance.put_channel(sid, :scheduler)
      refute Attendance.attended?(sid)
    end

    test "cli, tui and http sessions are attended", %{sid: sid} do
      for ch <- [:cli, :tui, :http] do
        Attendance.put_channel(sid, ch)
        assert Attendance.attended?(sid), "#{ch} should be attended"
      end
    end

    test "a loop state map answers from its own channel without a registration" do
      refute Attendance.attended?(%{session_id: "never_registered", channel: :headless})
      assert Attendance.attended?(%{session_id: "never_registered", channel: :cli})
    end

    test "the reason is reportable, so a silent auto-decision is not possible", %{sid: sid} do
      Attendance.put_channel(sid, :headless)
      assert Attendance.reason(sid) =~ "headless"
    end
  end

  describe "resolution order" do
    test "a sticky override beats the channel", %{sid: sid} do
      Attendance.put_channel(sid, :headless)
      Attendance.put_override(sid, true)
      assert Attendance.attended?(sid)

      Attendance.put_channel(sid, :cli)
      Attendance.put_override(sid, false)
      refute Attendance.attended?(sid)
    end

    test "OSA_ATTENDED beats the channel — a headless run WITH a human", %{sid: sid} do
      Attendance.put_channel(sid, :headless)

      System.put_env("OSA_ATTENDED", "1")
      assert Attendance.attended?(sid)

      System.put_env("OSA_ATTENDED", "off")
      refute Attendance.attended?(sid)
    end

    test "interactive_permissions=false is a hard veto over the channel", %{sid: sid} do
      Attendance.put_channel(sid, :cli)
      assert Attendance.attended?(sid)

      Application.put_env(:optimal_system_agent, :interactive_permissions, false)
      refute Attendance.attended?(sid)
    end

    test "interactive_permissions=true is NOT a claim that anyone is present", %{sid: sid} do
      # It is the config default, so it carries no information. A headless
      # session must stay unattended under it — this is the exact combination
      # `mix osa.run` produced, and the exact reason it parked.
      Application.put_env(:optimal_system_agent, :interactive_permissions, true)
      Attendance.put_channel(sid, :headless)
      refute Attendance.attended?(sid)
    end

    test "an UNREGISTERED session keeps the pre-Attendance answer" do
      # Not `false`. Turning previously-prompted calls into fail-closed
      # auto-decisions for a session we simply know nothing about would be a
      # change to a permission boundary dressed up as a bug fix. A tty votes
      # yes; otherwise the legacy flag (default true) decides, exactly as before.
      sid = "no_such_session_#{System.unique_integer([:positive])}"

      Application.put_env(:optimal_system_agent, :interactive_permissions, true)
      assert Attendance.attended?(sid)

      Application.put_env(:optimal_system_agent, :interactive_permissions, false)
      refute Attendance.attended?(sid)
    end
  end

  describe "the blocking paths do not park" do
    test "PermissionBroker.await returns immediately on a headless session", %{sid: sid} do
      Attendance.put_channel(sid, :headless)

      {us, result} =
        :timer.tc(fn -> PermissionBroker.await(sid, "perm_test_1", timeout: 300_000) end)

      assert result == {:error, :unattended}

      assert us < 500_000,
             "headless session parked for #{div(us, 1000)}ms on a permission prompt"
    end

    test "Survey.ask returns immediately on a headless session", %{sid: sid} do
      Attendance.put_channel(sid, :headless)

      {us, result} =
        :timer.tc(fn -> Survey.ask(sid, "survey_test_1", [], timeout: 120_000) end)

      assert result == {:error, :unattended}
      assert us < 500_000, "headless session parked for #{div(us, 1000)}ms on a survey"
    end

    test "an ATTENDED session still waits — the escape must not disable the feature",
         %{sid: sid} do
      Attendance.put_channel(sid, :cli)

      # A short ceiling: the point is that it polls rather than short-circuits.
      {us, result} = :timer.tc(fn -> PermissionBroker.await(sid, "perm_test_2", timeout: 600) end)

      assert result == {:error, :timeout}
      assert us > 400_000, "an attended session did not actually wait"
    end

    test "an answer delivered mid-wait still resolves an attended session", %{sid: sid} do
      Attendance.put_channel(sid, :cli)
      parent = self()

      spawn(fn ->
        Process.sleep(120)
        PermissionBroker.respond("perm_test_3", "allow")
        send(parent, :responded)
      end)

      assert {:ok, %{decision: :allow_once}} =
               PermissionBroker.await(sid, "perm_test_3", timeout: 5_000)

      assert_receive :responded, 2_000
    end
  end

  describe "unattended must fail closed, never self-approve" do
    test "an unattended verdict is not an allow", %{sid: sid} do
      Attendance.put_channel(sid, :headless)

      # The broker never grants. It reports that no answer can arrive; the
      # decision of what to do about that belongs to the caller, which fails
      # closed unless :non_interactive_permission_bypass is explicitly set.
      assert PermissionBroker.await(sid, "perm_test_4", timeout: 1_000) == {:error, :unattended}
    end

    test "a headless approval fails CLOSED and does not park", %{sid: sid} do
      # The whole defect, end to end: `mix osa.run` sets `channel: :headless`,
      # a mutating tool needs approval, and the old code took the interactive
      # branch and slept for up to 300s per prompt. It must now decide at once,
      # and the decision must be a BLOCK, not a self-approval.
      prior_bypass =
        Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      on_exit(fn ->
        Application.put_env(
          :optimal_system_agent,
          :non_interactive_permission_bypass,
          prior_bypass
        )
      end)

      state = struct(OptimalSystemAgent.Agent.Loop, session_id: sid, channel: :headless)
      Attendance.put_channel(sid, :headless)

      call = %{
        id: "tc_#{System.unique_integer([:positive])}",
        name: "file_write",
        arguments: %{
          "path" => Path.join(System.tmp_dir!(), "osa_attend_probe.txt"),
          "content" => "x"
        }
      }

      {us, result} =
        :timer.tc(fn ->
          OptimalSystemAgent.Agent.Loop.ToolExecutor.approve_tool_call(call, state)
        end)

      assert {:blocked, msg} = result
      assert msg =~ "fail closed"
      refute result == :allow

      assert us < 2_000_000,
             "headless approval took #{div(us, 1000)}ms — it parked instead of deciding"
    end

    test "a subagent inherits its parent's attendance, in both directions" do
      # `:internal` sessions publish their prompt up the RunStore chain to the
      # root (ToolExecutor.permission_topics/1), and `respond/2` is keyed by
      # request id alone — so an answer given at the root satisfies the child's
      # wait, and the honest verdict for the child is the ROOT's.
      #
      # This is what stops a teammate under a headless run from parking on a
      # prompt for 300s that nobody upstream can see either.
      root = "attend_root_#{System.unique_integer([:positive])}"
      child = "agent:#{root}:1"

      OptimalSystemAgent.Agent.RunStore.start_run(%{
        agent_id: child,
        parent_session_id: root,
        role: "researcher"
      })

      Attendance.put_channel(child, :internal)
      on_exit(fn -> Attendance.clear(child) end)
      on_exit(fn -> Attendance.clear(root) end)

      Attendance.put_channel(root, :headless)
      refute Attendance.attended?(child), "a subagent of a headless run must be unattended"

      Attendance.put_channel(root, :cli)
      assert Attendance.attended?(child), "a subagent of an attended run must be attended"
    end
  end
end
