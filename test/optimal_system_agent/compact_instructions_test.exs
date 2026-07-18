defmodule OptimalSystemAgent.CompactInstructionsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction

  # Arity/plumbing smoke for `/compact <instructions>`: every arity of
  # compact/1..3 must accept the call and return the list unchanged when the
  # history is too small to compact (no LLM round-trip attempted).
  test "compact/3 accepts optional custom instructions" do
    messages = [
      %{role: "user", content: "hello"},
      %{role: "assistant", content: "hi"}
    ]

    assert ProactiveCompaction.compact(messages) == messages
    assert ProactiveCompaction.compact(messages, "sess-1") == messages
    assert ProactiveCompaction.compact(messages, "sess-1", "focus on file changes") == messages
  end

  test "compact/3 tolerates non-binary instructions" do
    messages = [%{role: "user", content: "x"}]
    assert ProactiveCompaction.compact(messages, nil, 42) == messages
  end
end
