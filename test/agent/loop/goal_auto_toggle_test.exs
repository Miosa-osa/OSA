defmodule OptimalSystemAgent.Agent.Loop.GoalAutoToggleTest do
  @moduledoc """
  `/goal auto on|off` — a user-controllable kill switch for autonomous goal
  pursuit, separate from whether a goal, once anchored, can be worked at all.

  Requested: sometimes the user does NOT want OSA anchoring goals and
  auto-driving toward them — they want it to just do the task and stop. With
  the switch off:

    * the model's own `create_goal` tool call is refused outright (no
      spontaneous goal from an ordinary request);
    * `GoalTracker.enabled?/1` / `GoalVerifier.activated?/1` resolve `false`
      before ever consulting the autonomous-posture heuristic — no goal, new
      or already anchored, auto-continues or gets re-armed;
    * an EXPLICIT `/goal <text>` still anchors one — the switch is about the
      harness deciding to pursue something unasked, not about removing the
      feature.

  Deliberately independent of `permission_mode`/overdrive: full-auto TOOL
  execution and autonomous GOAL pursuit are two different questions, and
  turning one off must never silently turn off the other.

  Persisted via `Settings.set_user/2` — the SAME mechanism (`~/.osa/settings.json`,
  isolated per test run under `config_dir` in `:test`) the MCP server
  allow-list uses — so it survives across turns and across sessions, not just
  the current process.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Tools.Builtins.Goal.Handler

  defp sid, do: "goal-auto-toggle-#{System.unique_integer([:positive])}"

  defp capture_cli(fun), do: ExUnit.CaptureIO.capture_io(fun)

  # The setting is written to THIS test run's shared, isolated settings.json
  # (`config_dir` is per-run under `:test`, wiped at boot — see
  # `config/runtime.exs` — but not per-TEST), so a test that flips it must
  # restore the default itself or it leaks into every sibling test that runs
  # afterward in the same suite invocation.
  setup do
    on_exit(fn -> Settings.delete_user("goal_auto") end)
    :ok
  end

  describe "auto_enabled?/0 — the default" do
    test "is on when the setting was never touched" do
      assert GoalTracker.auto_enabled?()
    end

    test "false only for an explicit `false`, fail-safe against garbage" do
      Settings.set_user("goal_auto", "not-a-boolean")
      assert GoalTracker.auto_enabled?()

      Settings.set_user("goal_auto", nil)
      assert GoalTracker.auto_enabled?()

      Settings.set_user("goal_auto", false)
      refute GoalTracker.auto_enabled?()
    end
  end

  describe "/goal auto on|off — the slash command" do
    test "off, then status, then on — round-trips through the real settings file" do
      assert capture_cli(fn -> Commands.dispatch("goal auto", sid()) end) =~ "on"

      capture_cli(fn -> Commands.dispatch("goal auto off", sid()) end)
      refute GoalTracker.auto_enabled?()
      assert capture_cli(fn -> Commands.dispatch("goal auto", sid()) end) =~ "off"

      capture_cli(fn -> Commands.dispatch("goal auto on", sid()) end)
      assert GoalTracker.auto_enabled?()
      assert capture_cli(fn -> Commands.dispatch("goal auto", sid()) end) =~ "on"
    end

    # `/goal off` (bare) is a DIFFERENT, pre-existing command — it clears the
    # anchored goal. `/goal auto off` must not collide with it, and must not
    # fall through to `anchor_goal_command/2` and anchor a goal literally
    # titled "auto off".
    test "does not collide with the bare `/goal off` (clear) command" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")

      capture_cli(fn -> Commands.dispatch("goal auto off", s) end)

      assert GoalTracker.snapshot(s).goal == "ship the exporter",
             "/goal auto off must not have cleared or replaced the live goal"

      refute GoalTracker.auto_enabled?()
    end
  end

  describe "off disables auto-ANCHORING (create_goal)" do
    setup do
      ctx = %{session_id: sid()}
      on_exit(fn -> GoalTracker.reset(ctx.session_id) end)
      {:ok, ctx: ctx}
    end

    test "the model's own create_goal call is refused", %{ctx: ctx} do
      Settings.set_user("goal_auto", false)

      assert {:error, message, -32_602} =
               Handler.validate_create(%{"objective" => "ship the exporter"}, ctx)

      assert message =~ "off"
      refute GoalTracker.goal_loop?(ctx.session_id)
    end

    test "turning it back on restores create_goal", %{ctx: ctx} do
      Settings.set_user("goal_auto", false)
      assert {:error, _, _} = Handler.validate_create(%{"objective" => "ship it"}, ctx)

      Settings.set_user("goal_auto", true)
      assert {:ok, _} = Handler.validate_create(%{"objective" => "ship it"}, ctx)
    end

    test "an EXPLICIT /goal <text> still anchors one — the feature is not removed", %{
      ctx: ctx
    } do
      Settings.set_user("goal_auto", false)

      capture_cli(fn -> Commands.dispatch("goal ship the exporter", ctx.session_id) end)

      assert GoalTracker.goal_loop?(ctx.session_id),
             "an explicit /goal command must anchor regardless of the auto switch"
    end
  end

  describe "off disables auto-CONTINUE / re-arming, independent of overdrive" do
    setup do
      s = sid()
      on_exit(fn -> GoalTracker.reset(s) end)
      {:ok, session_id: s}
    end

    test "enabled?/1 is false even with an anchored goal loop", %{session_id: s} do
      GoalTracker.start(s, "ship the exporter")
      Settings.set_user("goal_auto", false)

      refute GoalTracker.enabled?(%{session_id: s}),
             "an anchored goal must not keep the tracker active once auto is off"

      refute GoalVerifier.activated?(%{session_id: s})
    end

    test "enabled?/1 is false even in overdrive — the two switches are independent", %{
      session_id: s
    } do
      Settings.set_user("goal_auto", false)
      state = %{session_id: s, permission_mode: :overdrive}

      assert GoalVerifier.autonomous_posture?(state),
             "overdrive alone still reads as autonomous posture — it is UNCHANGED by this switch"

      refute GoalTracker.enabled?(state),
             "but the goal-auto switch overrides posture regardless of overdrive"

      refute GoalVerifier.activated?(state)
    end

    test "overdrive with auto ON is unaffected — turning auto off must not be required to use overdrive",
         %{session_id: s} do
      state = %{session_id: s, permission_mode: :overdrive}

      assert GoalTracker.auto_enabled?()
      assert GoalTracker.enabled?(state)
      assert GoalVerifier.activated?(state)
    end

    test "a long turn's posture is likewise overridden by the switch", %{session_id: s} do
      previous =
        Application.get_env(:optimal_system_agent, :goal_verifier_activate_after_iterations)

      Application.put_env(:optimal_system_agent, :goal_verifier_activate_after_iterations, 3)

      on_exit(fn ->
        case previous do
          nil ->
            Application.delete_env(
              :optimal_system_agent,
              :goal_verifier_activate_after_iterations
            )

          v ->
            Application.put_env(
              :optimal_system_agent,
              :goal_verifier_activate_after_iterations,
              v
            )
        end
      end)

      state = %{session_id: s, iteration: 3}
      assert GoalVerifier.autonomous_posture?(state), "sanity: this alone reads as long-running"

      Settings.set_user("goal_auto", false)
      refute GoalTracker.enabled?(state)
      refute GoalVerifier.activated?(state)
    end
  end
end
