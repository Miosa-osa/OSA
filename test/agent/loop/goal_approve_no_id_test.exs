defmodule OptimalSystemAgent.Agent.Loop.GoalApproveNoIdTest do
  @moduledoc """
  Zero-ceremony `/goal approve` / `/goal reject`.

  Reported: a user should never have to run a manual command AND pass a goal
  id just to make an anchored goal continue. A session has at most one
  pending decision at a time (`GoalTracker`'s `pending_decision` is a single
  map, not a list), so requiring the id back was pure ceremony — and the old
  parser made it actively BROKEN for free-form rejection notes: it always
  read the first word after `reject`/`approve` as the id, so
  `/goal reject the button is still broken` tried to resolve request id
  `"the"` and failed with a confusing `stale_or_missing_request`, never having
  mentioned an id at all.

  `/goal approve` and `/goal reject <notes>` now resolve WHATEVER decision is
  currently pending, with no id required. An explicit `decision-<id>` (the
  exact shape `GoalTracker.request_decision/2` mints) is still accepted for
  callers that want it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Channels.CLI.Commands

  defp sid, do: "goal-approve-no-id-#{System.unique_integer([:positive])}"

  defp capture_cli(fun), do: ExUnit.CaptureIO.capture_io(fun)

  defp decision_request do
    %{
      "question" => "Ship as-is, or wait for the flaky test fix?",
      "criterion" => "user picks a direction",
      "work_summary" => "exporter works; one unrelated test is flaky",
      "artifact" => "lib/exporter.ex"
    }
  end

  setup do
    s = sid()
    GoalTracker.start(s, "ship the exporter")
    on_exit(fn -> GoalTracker.reset(s) end)
    {:ok, session_id: s}
  end

  describe "/goal approve — no id" do
    test "resolves the current pending decision with zero ceremony", %{session_id: sid} do
      {:ok, _} = GoalTracker.request_decision(sid, decision_request())
      assert GoalTracker.awaiting_user?(sid)

      output = capture_cli(fn -> Commands.dispatch("goal approve", sid) end)

      assert output =~ "Decision recorded"
      refute GoalTracker.awaiting_user?(sid)

      snap = GoalTracker.snapshot(sid)
      [entry | _] = snap.decision_history
      assert entry["decision"] == "approve"
    end

    test "with nothing pending, says so instead of demanding an id", %{session_id: sid} do
      refute GoalTracker.awaiting_user?(sid)

      output = capture_cli(fn -> Commands.dispatch("goal approve", sid) end)

      assert output =~ "No pending decision to approve"

      refute output =~ "request_id",
             "must never tell the user to go find/paste an id"
    end
  end

  describe "/goal reject <notes> — no id" do
    test "free-form rejection notes resolve the current decision instead of being read as an id",
         %{session_id: sid} do
      {:ok, _} = GoalTracker.request_decision(sid, decision_request())

      output =
        capture_cli(fn ->
          Commands.dispatch("goal reject the button is still broken", sid)
        end)

      assert output =~ "Decision recorded"

      refute output =~ "stale_or_missing_request",
             "notes with no id must never be misread as a stale/unknown id"

      snap = GoalTracker.snapshot(sid)
      [entry | _] = snap.decision_history
      assert entry["decision"] == "reject"
      assert entry["note"] == "the button is still broken"
    end
  end

  describe "explicit decision-<id> form still works (back-compat)" do
    test "an explicit, correct id still resolves its own decision", %{session_id: sid} do
      {:ok, snap} = GoalTracker.request_decision(sid, decision_request())
      id = snap.pending_decision["request_id"]

      output = capture_cli(fn -> Commands.dispatch("goal approve #{id} looks good", sid) end)

      assert output =~ "Decision recorded"
      final = GoalTracker.snapshot(sid)
      [entry | _] = final.decision_history
      assert entry["note"] == "looks good"
    end

    test "an explicit, STALE id is still rejected, not silently accepted", %{session_id: sid} do
      {:ok, _} = GoalTracker.request_decision(sid, decision_request())

      output =
        capture_cli(fn ->
          Commands.dispatch("goal approve decision-not-the-real-one", sid)
        end)

      assert output =~ "Decision not accepted"
      assert GoalTracker.awaiting_user?(sid), "a stale id must not resolve the real decision"
    end
  end
end
