defmodule OptimalSystemAgent.Agent.Loop.CompactionReachesTheWireTest do
  @moduledoc """
  Does compaction change what is SENT, or only what is displayed?

  Reported live: three folds ended at ~7.5k, and the very next turn sent 77.8k
  input tokens. The hypothesis that would subsume every other symptom in that
  report is that the fold rewrites a display-side view while request assembly
  still walks the original history — in which case the labels describe an
  internal state that never reaches the provider, and everything else follows.

  A screen assertion cannot tell "compacted" from "displayed as compacted", so
  this measures the thing the provider is actually handed:
  `Agent.Context.build/1`, which is the single assembly point every request
  goes through (`ReactLoop` line ~2581, `full = Context.build(state)`).

  These tests are about the CONVERSATION carried into the request. The static
  prefix (SYSTEM.md + tool schemas) is deliberately excluded from the size
  assertions — it is large, constant, and not something compaction claims to
  touch, so including it would only dilute the measurement.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction

  setup do
    for table <- [:osa_compactor_state, :osa_files_read] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  end

  defp filler, do: String.duplicate("lorem ipsum dolor sit amet consectetur ", 60)

  defp long_conversation(turns) do
    Enum.flat_map(1..turns, fn i ->
      [
        %{role: "user", content: "turn #{i}: #{filler()}"},
        %{role: "assistant", content: "reply #{i}: #{filler()}"}
      ]
    end)
  end

  # The conversation portion of an assembled request: everything the assembly
  # emitted after the leading system block.
  defp wire_conversation(state) do
    %{messages: assembled} = Context.build(state)
    Enum.reject(assembled, &(Map.get(&1, :role) == "system"))
  end

  defp wire_bytes(msgs) do
    msgs
    |> Enum.map(&to_string(Map.get(&1, :content, "")))
    |> Enum.join()
    |> byte_size()
  end

  test "a fold shrinks the request that is actually assembled, not just the label" do
    sid = "wire-#{System.unique_integer([:positive])}"
    messages = long_conversation(8)

    before_state = %{
      messages: messages,
      session_id: sid,
      provider: nil,
      model: nil,
      channel: :cli
    }

    before_wire = wire_conversation(before_state)

    compacted = ProactiveCompaction.compact(messages, sid)

    # Guard: if the fold declined, this test proves nothing either way.
    assert compacted != messages,
           "the fold declined to run — this test cannot answer the wire question"

    after_state = %{before_state | messages: compacted}
    after_wire = wire_conversation(after_state)

    assert length(after_wire) < length(before_wire),
           "compaction did not reduce the assembled request's message count: " <>
             "#{length(before_wire)} -> #{length(after_wire)}. That is the " <>
             "display-only failure mode: the fold changed a view the provider never sees."

    assert wire_bytes(after_wire) < wire_bytes(before_wire),
           "compaction did not reduce the assembled request's size: " <>
             "#{wire_bytes(before_wire)} -> #{wire_bytes(after_wire)} bytes"
  end

  test "request assembly reads the state's own message list, so a fold cannot be bypassed" do
    # The narrow structural claim underneath the test above: `Context.build/1`
    # has no second source of conversation history. If it ever grows one (a
    # durable transcript, a session store), a fold applied to `state.messages`
    # would stop reaching the wire and the test above is what catches it.
    sid = "wire-src-#{System.unique_integer([:positive])}"

    full = %{
      messages: long_conversation(6),
      session_id: sid,
      provider: nil,
      model: nil,
      channel: :cli
    }

    emptied = %{full | messages: []}

    assert wire_conversation(emptied) == [],
           "assembly produced conversation content from a state whose messages are empty — " <>
             "there is a second history source and compaction cannot be trusted to reach the wire"
  end
end
