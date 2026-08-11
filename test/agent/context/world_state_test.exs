defmodule OptimalSystemAgent.Agent.Context.WorldStateTest do
  @moduledoc """
  Diffed world state (Codex `world_state.rs` semantics).

  The contract under test:

    * an UNCHANGED section is not re-emitted on the next turn,
    * a CHANGED section IS re-emitted, carrying the replacement notice,
    * a REMOVED section emits its removal notice (a section must be able to say
      it went away, not just that it changed),
    * markers are append-only so injected context can always be stripped back
      out of persisted history.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Context.WorldState

  defp sid, do: "ws-#{:erlang.unique_integer([:positive])}"

  # {content, priority, label} — the shape Context.gather_dynamic_blocks/1 emits.
  defp blk(label, content), do: {content, 1, label}

  # One turn: returns {rendered_prompt_text, summary}.
  defp turn(session, blocks, opts \\ []) do
    {parts, summary} = WorldState.assemble(session, blocks, opts)
    {WorldState.text(parts), summary}
  end

  # What THIS turn actually added to the prompt.
  defp delta(before_text, after_text) do
    if String.starts_with?(after_text, before_text) do
      binary_part(
        after_text,
        byte_size(before_text),
        byte_size(after_text) - byte_size(before_text)
      )
    else
      # ledger compacted — treat the whole thing as newly emitted
      after_text
    end
  end

  describe "unchanged sections are not re-emitted" do
    test "turn 2 with identical blocks emits nothing new" do
      s = sid()
      blocks = [blk("tool_process", "USE TOOLS WISELY"), blk("commands", "/help — help")]

      {t1, sum1} = turn(s, blocks)
      assert sum1.emitted != []
      assert String.contains?(t1, "USE TOOLS WISELY")

      {t2, sum2} = turn(s, blocks)

      assert sum2.emitted == [], "unchanged sections must not be re-emitted"
      assert delta(t1, t2) == "", "turn 2 must add zero bytes to the prompt"
      assert t2 == t1, "the replayed ledger must be byte-identical (prefix cache stays warm)"
    end

    test "unchanged sections still appear in the prompt (replayed, not dropped)" do
      s = sid()
      blocks = [blk("tool_process", "TOOL DOCTRINE BODY")]

      turn(s, blocks)
      {t2, _} = turn(s, blocks)

      assert String.contains?(t2, "TOOL DOCTRINE BODY")
    end

    test "an unrelated section changing does not re-emit the untouched one" do
      s = sid()
      {t1, _} = turn(s, [blk("tool_process", "A"), blk("commands", "B")])
      {t2, sum} = turn(s, [blk("tool_process", "A"), blk("commands", "B-CHANGED")])

      assert sum.emitted == [:apps]
      d = delta(t1, t2)
      assert String.contains?(d, "B-CHANGED")
      refute String.contains?(d, "<ws id=\"tools\">")
    end
  end

  describe "changed sections re-emit with replacement semantics" do
    test "a changed AGENTS.md emits the replacement notice and the new body" do
      s = sid()
      {t1, _} = turn(s, [blk("project_context", "OLD RULES")])
      {t2, sum} = turn(s, [blk("project_context", "NEW RULES")])

      assert sum.changes[:agents_md] == :changed
      d = delta(t1, t2)

      assert String.contains?(
               d,
               "These AGENTS.md instructions replace all previously provided AGENTS.md instructions."
             )

      assert String.contains?(d, "NEW RULES")
    end

    test "a :plain section changes without a replacement notice" do
      s = sid()
      {t1, _} = turn(s, [blk("commands", "/a")])
      {t2, sum} = turn(s, [blk("commands", "/a /b")])

      assert sum.changes[:apps] == :changed
      d = delta(t1, t2)
      assert String.contains?(d, "/a /b")
      refute String.contains?(d, "replace all previously provided")
    end
  end

  describe "removed sections announce their removal" do
    test "dropping AGENTS.md emits the no-longer-applies notice" do
      s = sid()
      {t1, _} = turn(s, [blk("project_context", "RULES"), blk("commands", "/a")])
      {t2, sum} = turn(s, [blk("commands", "/a")])

      assert sum.changes[:agents_md] == :removed

      assert String.contains?(
               delta(t1, t2),
               "The previously provided AGENTS.md instructions no longer apply."
             )
    end

    test "exiting plan mode announces that the collaboration mode is gone" do
      s = sid()
      {t1, _} = turn(s, [blk("plan_mode", "## PLAN MODE — ACTIVE")])
      {t2, sum} = turn(s, [])

      assert sum.changes[:collaboration_mode] == :removed

      assert String.contains?(
               delta(t1, t2),
               "The previously provided collaboration mode instructions no longer apply."
             )
    end

    test "a removal is announced once, then stays quiet" do
      s = sid()
      turn(s, [blk("project_context", "RULES")])
      {t2, _} = turn(s, [])
      {t3, sum3} = turn(s, [])

      assert sum3.emitted == []
      assert delta(t2, t3) == ""
    end
  end

  describe "marker registry" do
    test "every emitted section is wrapped in its stable marker" do
      s = sid()
      {t, _} = turn(s, [blk("tool_process", "X"), blk("commands", "Y")])
      assert String.contains?(t, "<ws id=\"tools\">")
      assert String.contains?(t, "<ws id=\"apps\">")
    end

    test "strip/1 removes injected world state from persisted text" do
      s = sid()
      {t, _} = turn(s, [blk("tool_process", "INJECTED"), blk("commands", "ALSO")])
      persisted = "user said hello\n\n" <> t <> "\n\nand then this"

      stripped = WorldState.strip(persisted)

      refute String.contains?(stripped, "INJECTED")
      refute String.contains?(stripped, "ALSO")
      refute String.contains?(stripped, "<ws id=")
      assert String.contains?(stripped, "user said hello")
      assert String.contains?(stripped, "and then this")
    end

    test "markers/0 covers every registered section id, retired included" do
      ids = Enum.map(WorldState.sections(), & &1.id)
      assert length(WorldState.markers()) == length(ids)

      for id <- ids do
        assert WorldState.strip("<ws id=\"#{id}\">\nbody\n</ws>") == "",
               "marker for #{id} must still match — matchers are never deleted"
      end
    end

    test "section ids are unique and the registry is ordered" do
      ids = Enum.map(WorldState.sections(), & &1.id)
      assert ids == Enum.uniq(ids)
      assert :tools in ids
      assert :agents_md in ids
    end
  end

  describe "ledger hygiene" do
    test "emit: false diffs without advancing the ledger" do
      s = sid()
      turn(s, [blk("commands", "/a")])

      {probe, sum} = turn(s, [blk("commands", "/CHANGED")], emit: false)
      assert sum.changes[:apps] == :changed
      assert String.contains?(probe, "/CHANGED")

      # The real next turn must still see the change — the probe did not consume it.
      {_t, sum2} = turn(s, [blk("commands", "/CHANGED")])
      assert sum2.changes[:apps] == :changed
    end

    test "reset/1 clears the session ledger" do
      s = sid()
      turn(s, [blk("commands", "/a")])
      :ok = WorldState.reset(s)
      {_t, sum} = turn(s, [blk("commands", "/a")])
      assert sum.changes[:apps] == :added
    end

    test "invalidate/2 forces an evicted section to be re-emitted next turn" do
      s = sid()
      {_t, _} = turn(s, [blk("tool_process", "DOCTRINE"), blk("commands", "/a")])

      # Pretend the budget dropped the tools section this turn.
      :ok = WorldState.invalidate(s, [:tools])

      {t2, sum2} = turn(s, [blk("tool_process", "DOCTRINE"), blk("commands", "/a")])

      assert sum2.changes[:tools] == :added,
             "an evicted section must not stay suppressed as 'unchanged' forever"

      assert String.contains?(t2, "DOCTRINE")
    end

    test "a churning section compacts instead of growing without bound" do
      s = sid()

      texts =
        for i <- 1..12 do
          {t, _} = turn(s, [blk("commands", "/cmd-#{i}"), blk("tool_process", "T")])
          t
        end

      last = List.last(texts)
      # Compaction keeps the ledger bounded: the final text still carries the
      # CURRENT state and is nowhere near 12 stacked payloads.
      assert String.contains?(last, "/cmd-12")
      assert String.contains?(last, "<ws id=\"tools\">")
      assert byte_size(last) < byte_size(Enum.at(texts, 5)) + 2_000
    end

    test "blank content is treated as absent, not as a section" do
      s = sid()
      {t, sum} = turn(s, [blk("commands", "   "), blk("tool_process", "T")])
      refute sum.changes[:apps] == :added
      refute String.contains?(t, "<ws id=\"apps\">")
    end
  end
end
