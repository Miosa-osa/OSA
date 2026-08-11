defmodule OptimalSystemAgent.Events.TuiForwarderTest do
  @moduledoc """
  The TuiForwarder bridges Bus-only `:system_event` sub-events onto the
  per-session `osa:session:<id>` PubSub topic that the TUI streams, but ONLY for
  sub-events on its `@forward_events` allowlist. These tests pin that
  allowlist contract for `goal_verifier_round` (the goal-verification indicator)
  and confirm a non-allowlisted sub-event is NOT forwarded.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus

  setup do
    sid = "tui-forwarder-test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    {:ok, session_id: sid}
  end

  test "forwards goal_verifier_round (allowlisted) with its gaps intact", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: sid,
      round: 1,
      max_runs: 3,
      phase: :done,
      verdict: :incomplete,
      refuted_count: 2,
      total: 3,
      gaps: ["[completeness] error handling", "[verifiability] no test"]
    })

    assert_receive {:osa_event, event}, 2000
    assert event.type == :system_event
    assert event.event == :goal_verifier_round
    assert event.verdict == :incomplete
    assert event.gaps == ["[completeness] error handling", "[verifiability] no test"]
  end

  test "forwards session_title so the TUI status bar can name the session",
       %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :session_title,
      session_id: sid,
      title: "Debugging production 500 errors"
    })

    assert_receive {:osa_event, event}, 2000
    assert event.type == :system_event
    assert event.event == :session_title
    assert event.title == "Debugging production 500 errors"
  end

  test "ensure_title/3 puts a title on the wire without waiting for a model",
       %{session_id: sid} do
    # The end-to-end stage-1 path: an opening message titles the session AND the
    # title reaches the session topic, with no LLM call in the loop.
    tmp = Path.join(System.tmp_dir!(), "osa_titler_fwd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      File.rm_rf(tmp)
    end)

    :ok =
      OptimalSystemAgent.Memory.SessionTitler.ensure_title(
        sid,
        "debug 500 errors in production",
        refine: false
      )

    assert_receive {:osa_event, %{event: :session_title, title: title}}, 2000
    assert title == "Debug 500 errors in production"
  end

  test "forwards the lightweight start-phase signal too", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: sid,
      round: 1,
      max_runs: 3,
      phase: :start
    })

    assert_receive {:osa_event, %{event: :goal_verifier_round, phase: :start}}, 2000
  end

  test "forwards scratchpad_activity (allowlisted) with a compact payload and NO contents",
       %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :scratchpad_activity,
      session_id: sid,
      agent: "agent:#{sid}:1",
      entry: "findings.md",
      action: :write,
      bytes: 2100
    })

    assert_receive {:osa_event, event}, 2000
    assert event.type == :system_event
    assert event.event == :scratchpad_activity
    assert event.agent == "agent:#{sid}:1"
    assert event.entry == "findings.md"
    assert event.action == :write
    assert event.bytes == 2100
    # The activity signal must NEVER carry file contents — only who/what/size.
    refute Map.has_key?(event, :content)
    refute Map.has_key?(event, "content")
  end

  # ── ask_user → ask_user_question survey frame ────────────────────────
  #
  # Regression: `ask_user` was missing from the allowlist entirely, so the
  # question the tool blocks on never reached the session topic — the TUI
  # never opened its picker and the tool hung until its 5-minute timeout.

  describe "ask_user" do
    test "forwards the question as an ask_user_question survey frame", %{session_id: sid} do
      Bus.emit(:system_event, %{
        event: :ask_user,
        session_id: sid,
        ref: "#Reference<0.1.2.3>",
        question: "Which parser should we keep?",
        options: [
          "Rewrite the parser (Recommended) — removes the whole class of escaping bugs",
          "Patch in place — faster but the bug class stays"
        ]
      })

      assert_receive {:osa_event, event}, 2000
      assert event.type == :system_event
      # Renamed to the wire event the TUI's SSE parser decodes.
      assert event.event == :ask_user_question
      assert event.survey_id == "#Reference<0.1.2.3>"
      assert event.skippable == true

      assert [q] = event.questions
      assert q.text == "Which parser should we keep?"
      assert q.multi_select == false
      assert q.skippable == true

      assert [first, second] = q.options
      assert first.label == "Rewrite the parser (Recommended)"
      assert first.description == "removes the whole class of escaping bugs"
      assert second.label == "Patch in place"
      assert second.description == "faster but the bug class stays"
    end

    # The inline question band renders `header` as a small category chip before
    # the question text. It must survive the reshape, and be absent (nil) rather
    # than invented when the model omits it.
    test "forwards the optional category header", %{session_id: sid} do
      Bus.emit(:system_event, %{
        event: :ask_user,
        session_id: sid,
        ref: "r-hdr",
        question: "Which parser should we keep?",
        options: ["Yes", "No"],
        header: "parser"
      })

      assert_receive {:osa_event, event}, 2000
      assert [q] = event.questions
      assert q.header == "parser"
    end

    test "a question with no header forwards a nil chip", %{session_id: sid} do
      Bus.emit(:system_event, %{
        event: :ask_user,
        session_id: sid,
        ref: "r-nohdr",
        question: "Yes or no?",
        options: ["Yes", "No"]
      })

      assert_receive {:osa_event, event}, 2000
      assert [q] = event.questions
      assert q.header == nil
    end

    test "the forwarded frame is JSON-encodable (no PIDs)", %{session_id: sid} do
      Bus.emit(:system_event, %{
        event: :ask_user,
        session_id: sid,
        ref: "#Reference<0.9.9.9>",
        question: "Proceed?",
        options: [],
        # Even if an emitter leaks a PID, the reshape must drop it — a
        # non-encodable field made the SSE loop discard the whole frame.
        reply_to: self()
      })

      assert_receive {:osa_event, event}, 2000
      assert {:ok, json} = Jason.encode(event)
      assert json =~ "ask_user_question"
      refute json =~ "reply_to"
    end

    test "an option with no description survives as a bare label", %{session_id: sid} do
      Bus.emit(:system_event, %{
        event: :ask_user,
        session_id: sid,
        ref: "r1",
        question: "Yes or no?",
        options: ["Yes", "No"]
      })

      assert_receive {:osa_event, event}, 2000
      assert [q] = event.questions
      assert Enum.map(q.options, & &1.label) == ["Yes", "No"]
      assert Enum.all?(q.options, &is_nil(&1.description))
    end
  end

  test "does NOT forward a sub-event absent from the allowlist", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :some_unlisted_internal_event,
      session_id: sid,
      detail: "should stay Bus-only"
    })

    refute_receive {:osa_event, %{event: :some_unlisted_internal_event}}, 500
  end
end
