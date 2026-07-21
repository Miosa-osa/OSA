defmodule OptimalSystemAgent.Memory.StoreMergeTest do
  @moduledoc """
  Regression tests for the memory-fix subsystem (audit area: memory-subsystem).

  Covers the two P1 bugs:
    1. Over-aggressive merge at 0.40 keyword overlap silently collapsing two
       distinct facts into one garbled entry (memory/store.ex consolidate/2),
       plus the growth cap on merged content.
    2. Injector <-> shim infinite mutual-delegation recursion
       (agent/memory/injector.ex + lib/miosa/shims.ex).

  async: false — Memory.Store is a shared singleton GenServer.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Agent.Memory.Injector

  # Distinct facts that share ~0.6 of their keywords. Under the OLD code these
  # merged (any overlap >= 0.40 -> UPDATE); they must now stay separate.
  # Moderate keyword overlap (share the unique anchor "Zaxby" + prefers/
  # indentation, differ on tabs/Python vs spaces/Golang) — above the 0.40
  # candidate-link threshold but below the 0.75 merge threshold, so they must be
  # LINKED, not merged. The made-up "Zaxby" anchor keeps the pair from merging
  # with any residual memory in the shared singleton store. (Word-order-identical
  # pairs like "tabs over spaces" / "spaces over tabs" score ~1.0 under keyword
  # overlap and are a known heuristic limit, so they are avoided here.)
  @fact_a "Zaxby prefers tabs for Python indentation"
  @fact_b "Zaxby prefers spaces for Golang indentation"

  describe "consolidate/2 merge threshold (P1 correctness)" do
    test "two distinct facts with ~0.6 keyword overlap are stored separately" do
      assert {:ok, a} = Memory.save(@fact_a, category: :preference)
      assert {:ok, b} = Memory.save(@fact_b, category: :preference)

      refute a.id == b.id, "distinct facts must not collapse into one entry"

      # Each entry retains ITS OWN content — no \"Updated:\" garbling and no
      # cross-contamination between the two facts.
      assert a.content == @fact_a
      assert b.content == @fact_b
      refute a.content =~ "Golang"
      refute b.content =~ "Python"

      # Both are independently retrievable.
      assert {:ok, ga} = Memory.get(a.id)
      assert {:ok, gb} = Memory.get(b.id)
      assert ga.content == @fact_a
      assert gb.content == @fact_b
    end

    test "distinct-but-linked facts record an A-MEM link to the candidate" do
      assert {:ok, a} = Memory.save(@fact_a <> " for the api layer", category: :preference)
      assert {:ok, b} = Memory.save(@fact_b <> " for the api layer", category: :preference)

      refute a.id == b.id

      # b was ADDed (not merged) but still links back to the keyword-adjacent a.
      assert {:ok, gb} = Memory.get(b.id)
      assert a.id in decode_links(gb.links)
    end
  end

  describe "consolidate/2 high-overlap merge still works" do
    test "a near-identical refinement (overlap >= 0.75) merges into the existing entry" do
      base = "Always run pnpm lint before committing code changes to main"
      refined = "Always run pnpm lint before committing code changes to trunk"

      assert {:ok, first} = Memory.save(base, category: :decision)
      assert {:ok, second} = Memory.save(refined, category: :decision)

      # Merge updates the existing row in place (same id) and appends the
      # refinement as an \"Updated:\" segment.
      assert second.id == first.id
      assert second.content =~ "Updated:"
      assert second.content =~ base
      assert second.content =~ "trunk"
    end
  end

  describe "consolidate/2 growth cap (P1 correctness)" do
    test "an oversized existing entry is not appended to; the new fact is stored separately" do
      big = String.duplicate("alpha beta gamma delta ", 300)
      assert String.length(big) > 4_000

      assert {:ok, big_entry} = Memory.save(big, category: :context)

      # Overlap 0.8 (share alpha/beta/gamma/delta, add epsilon) -> would merge,
      # but the target row is oversized, so it must NOT be appended to.
      assert {:ok, new_entry} =
               Memory.save("alpha beta gamma delta epsilon", category: :context)

      refute new_entry.id == big_entry.id
      assert new_entry.content == "alpha beta gamma delta epsilon"

      assert {:ok, reloaded} = Memory.get(big_entry.id)
      refute reloaded.content =~ "epsilon", "oversized row must not accumulate more content"
    end
  end

  describe "Injector recursion landmine (P1 robustness)" do
    test "inject_relevant/2 returns without infinite mutual delegation" do
      # Before the fix this call recursed Agent.Memory.Injector ->
      # MiosaMemory.Injector -> Agent.Memory.Injector ... -> stack overflow.
      assert Injector.inject_relevant([], %{}) == []
    end

    test "inject_relevant/2 filters and ranks entries by relevance" do
      entries = [
        %{
          content: "python backend deploy notes",
          keywords: "python,backend,deploy",
          signal_weight: 0.9,
          relevance: 0.9
        },
        %{
          content: "unrelated cooking recipe",
          keywords: "cooking,recipe",
          signal_weight: 0.9,
          relevance: 0.9
        }
      ]

      result = Injector.inject_relevant(entries, %{query: "python deploy"})
      assert length(result) == 1
      assert hd(result).content =~ "python backend"
    end

    test "format_for_prompt/1 renders a memory block and handles empties" do
      assert Injector.format_for_prompt([]) == ""

      block = Injector.format_for_prompt([%{content: "remember this fact"}])
      assert block =~ "[System: Relevant memory]"
      assert block =~ "remember this fact"
    end

    test "MiosaMemory.Injector delegates one-way to the real implementation" do
      assert MiosaMemory.Injector.inject_relevant([], %{}) == []
      assert MiosaMemory.Injector.format_for_prompt([]) == ""
    end
  end

  defp decode_links(nil), do: []
  defp decode_links(""), do: []

  defp decode_links(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
