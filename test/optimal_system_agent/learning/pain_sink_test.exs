defmodule OptimalSystemAgent.Learning.PainSinkTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Learning.PainSink` — the narrow,
  ETS-backed consumer interface for turn-level pain events.

  async: false — the pain-event table is a shared, named ETS table.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Learning.{PainEvent, PainSink}

  setup do
    session_id = "pain-sink-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> PainSink.clear(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "record/4 and events/1" do
    test "buffers a recorded event, retrievable oldest-first", %{session_id: sid} do
      assert :ok = PainSink.record(sid, :repeated_probe, "first")
      assert :ok = PainSink.record(sid, :command_fix, "second")

      events = PainSink.events(sid)

      assert [
               %PainEvent{kind: :repeated_probe, detail: "first"},
               %PainEvent{kind: :command_fix, detail: "second"}
             ] =
               events
    end

    test "events are sanitised through PainEvent.new/4", %{session_id: sid} do
      PainSink.record(sid, :command_fix, "api_key=super-secret-value-1234 rejected")

      [event] = PainSink.events(sid)
      refute event.detail =~ "super-secret-value-1234"
    end

    test "different sessions never see each other's events", %{session_id: sid} do
      other = sid <> "-other"
      on_exit(fn -> PainSink.clear(other) end)

      PainSink.record(sid, :repeated_probe, "mine")
      PainSink.record(other, :repeated_probe, "theirs")

      assert [%PainEvent{detail: "mine"}] = PainSink.events(sid)
      assert [%PainEvent{detail: "theirs"}] = PainSink.events(other)
    end

    test "a nil or non-binary session_id is a safe no-op" do
      assert :ok = PainSink.record(nil, :repeated_probe, "x")
      assert PainSink.events(nil) == []
    end

    test "returns :ok even when metadata is omitted", %{session_id: sid} do
      assert :ok = PainSink.record(sid, :other, "detail")
    end
  end

  describe "cap enforcement" do
    test "buffering far beyond the cap keeps the buffer bounded and keeps the newest",
         %{session_id: sid} do
      for n <- 1..320 do
        PainSink.record(sid, :repeated_probe, "event #{n}")
      end

      events = PainSink.events(sid)
      assert length(events) <= 300
      assert List.last(events).detail == "event 320"
    end
  end

  describe "clear/1" do
    test "drops every buffered event for a session", %{session_id: sid} do
      PainSink.record(sid, :repeated_probe, "x")
      assert PainSink.events(sid) != []

      assert :ok = PainSink.clear(sid)
      assert PainSink.events(sid) == []
    end

    test "clearing an already-empty session is a safe no-op" do
      assert :ok = PainSink.clear("never-recorded-session")
    end
  end

  describe "test_event/2" do
    test "synthesises one event of the given kind for pipeline exercise", %{session_id: sid} do
      assert :ok = PainSink.test_event(sid, :wrong_checkout)

      assert [%PainEvent{kind: :wrong_checkout, metadata: %{synthetic: true}}] =
               PainSink.events(sid)
    end
  end
end
