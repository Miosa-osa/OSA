defmodule OptimalSystemAgent.Agent.Loop.MessageSegmentTest do
  @moduledoc """
  One assistant segment is one `message_id`.

  The TUI treats `message_id` as message identity: a delta whose id differs from
  the one currently accumulating closes the open block and opens a new `◈ OSA`
  one (`app/assistant_stream.rs`, `push/2`'s `new_generation`). That is correct
  client behaviour, so the id is the contract, and minting it per LLM round-trip
  was what tore a single answer into two headers mid-thought: the verification
  gate / output-token target / compaction boundary / stop hooks all re-enter
  `ReactLoop.run/1` with no tool call in between, and each re-entry minted.

  The rule these tests pin: a continuation KEEPS the id, a tool run ENDS the
  segment, a new turn RESETS it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient

  # `llm_chat/3` needs a provider it can actually dispatch to; `:mock` is
  # registered in the provider registry under Mix.env() == :test. What is under
  # test is the id bookkeeping around the call, not the reply.
  @state %{provider: :mock, model: "mock-model-1.0", session_id: "seg-test"}

  setup do
    LLMClient.reset_message_id()
    Process.delete(:mock_provider_call_count)
    on_exit(fn -> LLMClient.reset_message_id() end)
    :ok
  end

  defp generate! do
    {:ok, _} = LLMClient.llm_chat(@state, [%{role: "user", content: "hi"}], [])
    LLMClient.current_message_id()
  end

  test "a turn with no generation carries no id" do
    refute LLMClient.current_message_id()
  end

  test "the first generation of a turn mints an id" do
    id = generate!()
    assert is_binary(id)
    assert String.starts_with?(id, "seg-test-m")
  end

  test "a continuation with no tool call in between keeps the SAME id" do
    first = generate!()
    second = generate!()

    assert second == first,
           "a text-only continuation must extend the open segment; a new id makes the " <>
             "TUI close the block the user is reading and open a second ◈ OSA header " <>
             "mid-answer"
  end

  test "a generation after a tool run mints a NEW id" do
    first = generate!()
    LLMClient.start_new_message_segment()
    second = generate!()

    refute second == first,
           "a tool cell is drawn between the text before it and the text after it — " <>
             "those really are two blocks"
  end

  test "ending a segment does not blank the current id" do
    id = generate!()
    LLMClient.start_new_message_segment()

    assert LLMClient.current_message_id() == id,
           "the turn-final agent_response stamps current_message_id/0; a tool run that " <>
             "turns out to end the turn must still finalize the segment it belongs to " <>
             "rather than send nil and drop the client to its id-less legacy path"
  end

  test "only the next generation consumes the segment break" do
    _first = generate!()
    LLMClient.start_new_message_segment()
    second = generate!()
    third = generate!()

    assert third == second, "the break is one-shot, not a mode"
  end

  test "a new turn resets identity so the client cannot read it as a repeat" do
    _id = generate!()
    LLMClient.reset_message_id()

    refute LLMClient.current_message_id()
  end

  test "a segment break does not survive a turn reset" do
    first = generate!()
    LLMClient.start_new_message_segment()
    LLMClient.reset_message_id()
    second = generate!()

    refute second == first
    assert is_binary(second)
  end
end
