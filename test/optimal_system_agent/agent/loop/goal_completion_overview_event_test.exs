defmodule OptimalSystemAgent.Agent.Loop.GoalCompletionOverviewEventTest do
  @moduledoc """
  #3 — a structured `:goal_completion_overview` event (and its
  `GoalTracker.completion_overview/1` accessor) fires exactly once a goal
  reaches a TERMINAL state (`:completed`, `:blocked`, `:abandoned`), carrying
  the panel's actual gap list, a work summary, and the frozen acceptance
  criteria — not just a status atom — so a TUI completion panel has
  everything it needs on one frame instead of replaying `/goal status`.

  `:paused` (a stall/run-cap/manual pause) is deliberately NOT terminal —
  `/goal resume` still applies to it — so it must never emit this event.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.{GoalTracker, GoalVerifier}
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Events.Bus

  defp sid, do: "goal-overview-event-#{System.unique_integer([:positive])}"

  defp record_write(session_id, path) do
    Ledger.record(session_id, %{tool: "file_write", args: %{"path" => path}, success: true})
  end

  # Filter on THIS test's session_id — the Bus dispatches handlers via
  # asynchronous supervised Tasks, so a stray event from a prior test can
  # still be in flight when this one registers its own handler.
  defp capture_completion_events(sid) do
    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        data =
          case payload do
            %{data: d} when is_map(d) -> d
            d when is_map(d) -> d
          end

        if data[:event] == :goal_completion_overview and data[:session_id] == sid do
          send(test_pid, {:completion_overview_event, data})
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
    ref
  end

  setup do
    s = sid()

    on_exit(fn ->
      GoalTracker.reset(s)
      Ledger.reset(s)
    end)

    {:ok, session_id: s}
  end

  describe "completion_overview/1" do
    test "nil for a non-terminal goal (:active)", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter")
      assert GoalTracker.completion_overview(sid) == nil
    end

    test "nil for a paused goal — resumable is not terminal", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter")
      GoalTracker.pause(sid, :no_progress)
      assert GoalTracker.completion_overview(sid) == nil
    end

    test "nil for an awaiting_user goal", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter")

      GoalTracker.request_decision(sid, %{
        "question" => "ship it?",
        "criterion" => "tests pass",
        "work_summary" => "done",
        "artifact" => "PR #1"
      })

      assert GoalTracker.completion_overview(sid) == nil
    end

    test "the full structured payload for a completed goal", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter",
        acceptance_criteria: "mix test passes and lib/exporter.ex exports dump/1"
      )

      record_write(sid, "lib/widget/exporter.ex")
      record_write(sid, "test/widget/exporter_test.exs")

      GoalTracker.advance(sid, %GoalVerifier.Result{
        verdict: :complete,
        reason: "all acceptance criteria met"
      })

      overview = GoalTracker.completion_overview(sid)

      assert overview.status == :completed
      assert overview.goal == "ship the widget exporter"
      assert overview.gaps == []
      assert overview.acceptance_criteria == "mix test passes and lib/exporter.ex exports dump/1"
      assert Enum.any?(overview.work_summary, &String.ends_with?(&1, "lib/widget/exporter.ex"))

      assert Enum.any?(
               overview.work_summary,
               &String.ends_with?(&1, "test/widget/exporter_test.exs")
             )

      assert is_binary(overview.latest)
      assert overview.session_id == sid
    end

    test "a blocked goal reports its blocker, not a panel verdict", %{session_id: sid} do
      GoalTracker.start(sid, "deploy to the locked-down environment")
      record_write(sid, "infra/deploy.yml")

      {:pending, 1, _} = GoalTracker.claim_blocked(sid)
      GoalTracker.tick_turn(sid)
      {:pending, 2, _} = GoalTracker.claim_blocked(sid)
      GoalTracker.tick_turn(sid)
      {:blocked, _} = GoalTracker.claim_blocked(sid)

      overview = GoalTracker.completion_overview(sid)

      assert overview.status == :blocked
      assert overview.pause_reason == :blocked
      assert Enum.any?(overview.work_summary, &String.ends_with?(&1, "infra/deploy.yml"))
    end

    test "an abandoned goal", %{session_id: sid} do
      GoalTracker.start(sid, "a goal that changed direction")
      {:ok, _} = GoalTracker.abandon(sid)

      overview = GoalTracker.completion_overview(sid)
      assert overview.status == :abandoned
    end

    test "gaps carry the panel's actual findings, not just a count", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter")

      gaps = [
        "[completeness] the CSV export path is missing",
        "[verifiability] no test proves it"
      ]

      GoalTracker.advance(sid, %GoalVerifier.Result{
        verdict: :incomplete,
        reason: "not yet",
        gaps: gaps
      })

      GoalTracker.advance(sid, %GoalVerifier.Result{verdict: :complete, reason: "now fixed"})

      # Completion clears last_gaps (nothing outstanding) — the gap list is
      # meaningful on a PAUSED/blocked overview, not a completed one. Assert
      # the clean-slate side explicitly so a future regression that leaks
      # stale gaps into a completed overview is caught.
      overview = GoalTracker.completion_overview(sid)
      assert overview.gaps == []
    end
  end

  describe "the :goal_completion_overview Bus event" do
    test "fires once, with the gap list, when the panel completes the goal", %{session_id: sid} do
      capture_completion_events(sid)
      GoalTracker.start(sid, "ship the widget exporter")
      record_write(sid, "lib/widget/exporter.ex")

      GoalTracker.advance(sid, %GoalVerifier.Result{verdict: :complete, reason: "done"})

      assert_receive {:completion_overview_event, data}, 1_000
      assert data.status == :completed
      assert data.session_id == sid
      assert Enum.any?(data.work_summary, &String.ends_with?(&1, "lib/widget/exporter.ex"))

      refute_receive {:completion_overview_event, _}, 200
    end

    test "does NOT fire for a mere pause (stall/run-cap) — not terminal", %{session_id: sid} do
      capture_completion_events(sid)
      GoalTracker.start(sid, "ship the widget exporter")

      GoalTracker.advance(sid, %GoalVerifier.Result{
        verdict: :incomplete,
        reason: "stuck",
        gaps: ["same gap"]
      })

      GoalTracker.advance(sid, %GoalVerifier.Result{
        verdict: :incomplete,
        reason: "still stuck",
        gaps: ["same gap"]
      })

      assert GoalTracker.paused?(sid)
      refute_receive {:completion_overview_event, _}, 200
    end

    test "fires when the model's blocked claim actually trips the threshold", %{
      session_id: sid
    } do
      capture_completion_events(sid)
      GoalTracker.start(sid, "deploy to the locked-down environment")

      {:pending, 1, _} = GoalTracker.claim_blocked(sid)
      refute_receive {:completion_overview_event, _}, 100
      GoalTracker.tick_turn(sid)

      {:pending, 2, _} = GoalTracker.claim_blocked(sid)
      refute_receive {:completion_overview_event, _}, 100
      GoalTracker.tick_turn(sid)

      {:blocked, _} = GoalTracker.claim_blocked(sid)
      assert_receive {:completion_overview_event, data}, 1_000
      assert data.status == :blocked
    end

    test "fires on abandon", %{session_id: sid} do
      capture_completion_events(sid)
      GoalTracker.start(sid, "a goal that changed direction")

      {:ok, _} = GoalTracker.abandon(sid)

      assert_receive {:completion_overview_event, data}, 1_000
      assert data.status == :abandoned
    end
  end
end
