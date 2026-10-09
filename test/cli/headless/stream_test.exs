defmodule OptimalSystemAgent.CLI.Headless.StreamTest do
  @moduledoc """
  The `osa run --format stream-json` event schema, message by message: what a
  session's live events become on the wire.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.CLI.Headless
  alias OptimalSystemAgent.CLI.Headless.Stream

  @sid "headless-1-test"

  defp feed(messages, state \\ Stream.new(@sid)) do
    Enum.reduce(messages, {[], state}, fn message, {acc, st} ->
      {events, st} = Stream.handle(st, message)
      {acc ++ events, st}
    end)
  end

  defp token(text, id \\ "m1"),
    do: {:osa_event, %{type: :streaming_token, text: text, message_id: id}}

  test "tokens stream, and the message is flushed as one assistant event before a tool" do
    {events, state} =
      feed([
        token("Let me "),
        token("check."),
        {:osa_tool_stream, :use,
         %{id: "call_1", name: "shell_execute", input: %{"command" => "ls"}}},
        {:osa_tool_stream, :result,
         %{
           id: "call_1",
           name: "shell_execute",
           content: "a\nb",
           is_error: false,
           truncated: false
         }}
      ])

    assert Enum.map(events, & &1.type) == ~w(token token assistant tool_use tool_result)
    assert Enum.all?(events, &(&1.session_id == @sid))

    assert Enum.at(events, 2).message == %{
             role: "assistant",
             content: [%{type: "text", text: "Let me check."}]
           }

    assert %{id: "call_1", name: "shell_execute", input: %{"command" => "ls"}} =
             Enum.at(events, 3)

    assert %{tool_use_id: "call_1", content: "a\nb", is_error: false, truncated: false} =
             Enum.at(events, 4)

    assert state.assistant_messages == 1
  end

  test "a new message id closes the previous message" do
    {events, _} = feed([token("first", "m1"), token("second", "m2")])
    assert Enum.map(events, & &1.type) == ~w(token assistant token)
    assert Enum.at(events, 1).message.content == [%{type: "text", text: "first"}]
  end

  test "finish flushes the streamed text; a non-streaming answer becomes the assistant event" do
    {_, state} = feed([token("Done.")])
    {events, _} = Stream.finish(state, "Done.")
    assert [%{type: "assistant"}] = events

    {events, _} = Stream.finish(Stream.new(@sid), "Answer without deltas")

    assert [%{type: "assistant", message: %{content: [%{text: "Answer without deltas"}]}}] =
             events

    assert {[], _} = Stream.finish(Stream.new(@sid), nil)
  end

  test "thinking deltas" do
    {events, _} = feed([{:osa_event, %{type: :thinking_delta, text: "hmm"}}])
    assert [%{type: "thinking", delta: "hmm"}] = events
  end

  test "usage: one event per round-trip, never the stream-terminator duplicate" do
    {events, _} =
      feed([
        {:osa_event,
         %{type: :llm_response, duration_ms: 0, cache_status: %{}, usage: %{input_tokens: 9}}},
        {:osa_event,
         %{
           type: :llm_response,
           duration_ms: 120,
           usage: %{input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 4}
         }}
      ])

    assert [
             %{
               type: "usage",
               duration_ms: 120,
               usage: %{
                 input_tokens: 10,
                 output_tokens: 2,
                 cache_read_tokens: 4,
                 cache_creation_tokens: 0
               }
             }
           ] = events
  end

  test "compaction start and end, success and failure" do
    {events, state} =
      feed([
        {:osa_event,
         %{type: :system_event, event: :compaction_started, trigger: "auto", tokens_before: 900}},
        {:osa_event,
         %{
           type: :system_event,
           event: :compaction_completed,
           tokens_before: 900,
           tokens_after: 200,
           messages_before: 40,
           messages_after: 6,
           duration_ms: 1500
         }},
        {:osa_event,
         %{type: :system_event, event: :compaction_failed, reason: "timeout", duration_ms: 9}}
      ])

    assert [
             %{type: "compaction_start", trigger: "auto", tokens_before: 900},
             %{type: "compaction_end", success: true, tokens_before: 900, tokens_after: 200},
             %{type: "compaction_end", success: false, error: "timeout"}
           ] = events

    assert state.compactions == 1
  end

  test "context pressure is remembered for the result, a turn error is recorded" do
    {[], state} =
      feed([
        {:osa_event,
         %{
           type: :context_pressure,
           estimated_tokens: 5000,
           max_tokens: 100_000,
           utilization: 5.0,
           compact_at: 75_000
         }},
        {:osa_event, %{type: :agent_response, turn_error: %{reason: "503", owner: :provider}}}
      ])

    assert state.context == %{
             used_tokens: 5000,
             window_tokens: 100_000,
             percent: 5.0,
             compact_at_tokens: 75_000
           }

    assert state.turn_error == %{reason: "503", owner: :provider}
  end

  test "unrelated session events produce nothing" do
    assert {[], _} = feed([{:osa_event, %{type: :tool_call, phase: "start"}}, :noise])
  end

  describe "the JSON line" do
    test "type, subtype and session_id lead, the rest in key order" do
      line =
        Headless.json_line(%{
          zeta: 1,
          session_id: "s",
          type: "system",
          subtype: "init",
          alpha: 2
        })

      assert line == ~s({"type":"system","subtype":"init","session_id":"s","alpha":2,"zeta":1})
    end

    test "lossless and terminal-inert" do
      text = "esc \e[31m bel \a c1 \u009b done"
      line = Headless.json_line(%{type: "token", delta: text})
      refute line =~ "\e"
      assert Jason.decode!(line)["delta"] == text
    end
  end

  describe "stream-json input lines" do
    test "Claude Code's user message, string or blocks" do
      assert Headless.input_message(~s({"type":"user","message":{"role":"user","content":"hi"}})) ==
               {:ok, "hi"}

      assert Headless.input_message(
               ~s({"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}})
             ) == {:ok, "a\nb"}
    end

    test "short forms, blanks and errors" do
      assert Headless.input_message(~s({"type":"user","content":"x"})) == {:ok, "x"}
      assert Headless.input_message(~s({"prompt":"y"})) == {:ok, "y"}
      assert Headless.input_message("  \n") == :skip
      assert {:error, _} = Headless.input_message("not json")
      assert {:error, _} = Headless.input_message(~s({"type":"control"}))
      assert {:error, _} = Headless.input_message(~s({"type":"user","content":"  "}))
    end
  end
end
