defmodule OptimalSystemAgent.Store.TranscriptPersistenceTest do
  @moduledoc """
  Regression tests for session transcript persistence (audit area:
  session-persistence). Covers: assistant-only writes from the
  post_response handler, ingestion-time user-turn saves, content-block
  coercion, and user-before-assistant ordering on same-second inserts.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks.Handlers
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Store.SessionTranscript

  defp unique_sid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp roles_contents(sid) do
    sid |> SessionTranscript.get_transcript() |> Enum.map(&{&1.role, &1.content})
  end

  describe "SessionTranscript.save_turn/4 content coercion" do
    test "persists plain binary content unchanged" do
      sid = unique_sid("coerce-bin")
      assert {:ok, rec} = SessionTranscript.save_turn(sid, "user", "hello world")
      assert rec.content == "hello world"
    end

    test "flattens content-block lists (vision turns) instead of failing the cast" do
      sid = unique_sid("coerce-blocks")

      blocks = [
        %{type: "text", text: "what is in this image?"},
        %{type: "image", source: %{type: "base64", media_type: "image/png", data: "AAAA"}}
      ]

      assert {:ok, rec} = SessionTranscript.save_turn(sid, "user", blocks)
      assert rec.content =~ "what is in this image?"
      assert rec.content =~ "[image]"
      assert [{"user", _}] = roles_contents(sid)
    end
  end

  describe "save_transcript post_response handler" do
    test "persists ONLY the assistant turn (user turn is saved at ingestion)" do
      sid = unique_sid("handler")

      payload = %{
        session_id: sid,
        input: "the real user prompt",
        response: "the streamed assistant reply"
      }

      assert {:ok, _} = Handlers.save_transcript(payload)
      assert roles_contents(sid) == [{"assistant", "the streamed assistant reply"}]
    end

    test "persisted assistant content equals the streamed final string verbatim" do
      sid = unique_sid("stream")
      streamed = "line one\nline two — final accumulated text"

      assert {:ok, _} = Handlers.save_transcript(%{session_id: sid, input: "q", response: streamed})
      assert roles_contents(sid) == [{"assistant", streamed}]
    end

    test "skips empty assistant response and never writes a user row" do
      sid = unique_sid("empty")
      assert {:ok, _} = Handlers.save_transcript(%{session_id: sid, input: "question", response: ""})
      assert roles_contents(sid) == []
    end
  end

  describe "TurnPipeline.persist_user_turn/2 (ingestion-time user save)" do
    test "persists the raw user prompt under role user" do
      sid = unique_sid("ingest")
      assert :ok = TurnPipeline.persist_user_turn(sid, "please fix the bug")
      assert roles_contents(sid) == [{"user", "please fix the bug"}]
    end

    test "ignores empty and non-binary messages" do
      sid = unique_sid("ingest-empty")
      assert :ok = TurnPipeline.persist_user_turn(sid, "")
      assert :ok = TurnPipeline.persist_user_turn(sid, nil)
      assert roles_contents(sid) == []
    end
  end

  describe "transcript ordering and session listing" do
    test "user-then-assistant rows in the same second keep insertion order" do
      sid = unique_sid("order")

      TurnPipeline.persist_user_turn(sid, "first question")
      Handlers.save_transcript(%{session_id: sid, response: "first answer"})
      TurnPipeline.persist_user_turn(sid, "second question")
      Handlers.save_transcript(%{session_id: sid, response: "second answer"})

      assert roles_contents(sid) == [
               {"user", "first question"},
               {"assistant", "first answer"},
               {"user", "second question"},
               {"assistant", "second answer"}
             ]
    end

    test "list_sessions first_message is the user's prompt, not the assistant reply" do
      sid = unique_sid("firstmsg")

      TurnPipeline.persist_user_turn(sid, "what is the plan?")
      Handlers.save_transcript(%{session_id: sid, response: "here is the plan"})

      session =
        SessionTranscript.list_sessions(limit: 200)
        |> Enum.find(&(&1.session_id == sid))

      assert session
      assert session.first_message == "what is the plan?"
    end
  end
end
