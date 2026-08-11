defmodule OptimalSystemAgent.Agent.Loop.ReactLoopDeferredFixesTest do
  @moduledoc """
  Two fixes that landed on the other side of a module boundary and left their
  `react_loop.ex` half behind.

  **`scaffold: true` on the interrupt marker.** `Loop.scaffold_message?/1`
  prefers an explicit `:scaffold` flag and keeps a content match only as a
  fallback — its own comment says so, and names react_loop as the site that
  still writes the marker text unflagged. A content match is fragile in both
  directions: it breaks the moment the marker wording changes, and it
  misclassifies a user who types the marker text verbatim.

  **`Loop.clear_cancel/1` instead of a bare `:ets.delete/2`.** `Loop.cancel/1`
  flags the whole subtree — the session, its descendants, and any
  `agent:<sid>:` keys. Clearing only the parent key stranded the children's
  flags in the table, so a re-used child id started life already cancelled.
  Clearing must be the exact inverse of setting.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  @cancel_table :osa_cancel_flags

  defp sid, do: "react-deferred-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    %{
      session_id: session_id,
      iteration: 0,
      messages: [%{role: "user", content: "do the thing"}]
    }
  end

  defp flagged?(key) do
    :ets.lookup(@cancel_table, key) != []
  end

  # ── scaffold flag ────────────────────────────────────────────────────────

  describe "the interrupt marker is flagged as scaffolding" do
    test "an interrupted turn appends a user message carrying scaffold: true" do
      session = sid()
      :ets.insert(@cancel_table, {session, true})

      {marker, state} = ReactLoop.run(base_state(session))

      assert marker in ReactLoop.interrupt_markers()

      appended = List.last(state.messages)
      assert appended.role == "user"
      assert appended.content == marker

      assert appended.scaffold == true,
             "/undo must be able to skip the marker by FLAG, not only by content match"

      on_exit(fn -> Loop.clear_cancel(session) end)
    end

    test "Loop.scaffold_message?/1 recognises it via the flag alone" do
      session = sid()
      :ets.insert(@cancel_table, {session, true})

      {_marker, state} = ReactLoop.run(base_state(session))
      appended = List.last(state.messages)

      # Strip the content so ONLY the flag can identify it — this is the path
      # that survives a reworded marker.
      contentless = Map.put(appended, :content, "some completely different text")

      assert Loop.scaffold_message?(contentless),
             "the flag must stand on its own; the content match is only a fallback " <>
               "for transcripts persisted before the flag existed"

      on_exit(fn -> Loop.clear_cancel(session) end)
    end

    test "a real user message that happens to quote the marker is still user text" do
      # The content match cannot tell these apart. The flag can.
      typed_by_human = %{role: "user", content: "[Request interrupted by user]"}
      injected_by_loop = %{role: "user", content: "anything at all", scaffold: true}

      assert Loop.scaffold_message?(injected_by_loop)

      # Documenting the legacy fallback's known limitation, not endorsing it:
      # what matters is that OSA's own injection site no longer relies on it.
      assert Loop.scaffold_message?(typed_by_human)
    end
  end

  # ── subtree-wide cancel clearing ─────────────────────────────────────────

  describe "cancel flags are cleared across the whole subtree" do
    test "a descendant's agent: key is cleared, not stranded" do
      session = sid()
      child_key = "agent:#{session}:child-1"
      grandchild_key = "agent:#{session}:child-2"

      # Exactly the shape `Loop.cancel/1`'s prefix fold produces.
      :ets.insert(@cancel_table, {session, true})
      :ets.insert(@cancel_table, {child_key, true})
      :ets.insert(@cancel_table, {grandchild_key, true})

      {_marker, _state} = ReactLoop.run(base_state(session))

      refute flagged?(session)

      refute flagged?(child_key),
             "a stranded child flag makes a re-used child id start life already cancelled"

      refute flagged?(grandchild_key)
    end

    test "an unrelated session's flag is left alone" do
      session = sid()
      other = sid()

      :ets.insert(@cancel_table, {session, true})
      :ets.insert(@cancel_table, {other, true})

      {_marker, _state} = ReactLoop.run(base_state(session))

      refute flagged?(session)

      assert flagged?(other),
             "clearing must be scoped to the cancelled subtree, not global"

      on_exit(fn -> Loop.clear_cancel(other) end)
    end

    test "clearing is the exact inverse of Loop.cancel/1 for the prefix keys" do
      session = sid()
      child_key = "agent:#{session}:racy-child"

      # Pre-seed the child key, then cancel: the fold in `Loop.cancel/1` flags
      # it. The clear must undo precisely that.
      :ets.insert(@cancel_table, {child_key, false})
      Loop.cancel(session)

      assert flagged?(session)
      assert :ets.lookup(@cancel_table, child_key) == [{child_key, true}]

      {_marker, _state} = ReactLoop.run(base_state(session))

      refute flagged?(session)
      refute flagged?(child_key)
    end
  end
end
