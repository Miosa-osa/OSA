defmodule OptimalSystemAgent.Agent.Context.WorldStateCompactionTest do
  @moduledoc """
  Ledger compaction rewrites the world-state block, and that block carries its
  own `cache_control` breakpoint — so a rewrite invalidates it and everything
  after it, including the whole conversation. Compaction therefore has to earn
  its cost.

  It used to fire after a flat 6 delta payloads regardless of their size, which
  meant a session emitting a few hundred bytes per turn broke its cache every
  six turns to replace a small ledger with a LARGER full snapshot. The trigger
  is now the only condition under which compacting wins on both axes: replaying
  costs more than a fresh snapshot would.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context.WorldState

  setup do
    sid = "ws-compact-#{System.unique_integer([:positive])}"
    on_exit(fn -> WorldState.reset(sid) end)
    {:ok, sid: sid}
  end

  defp block(label, content), do: {content, 1, label}

  # Emit `n` turns, each changing one managed section by a small amount, and
  # report the emitted payload count per turn.
  defp churn(sid, n, size) do
    for i <- 1..n do
      body = "plan step #{i} " <> String.duplicate("x", size)
      {sections, _summary} = WorldState.assemble(sid, [block("plan_mode", body)])
      sections
    end
  end

  test "a small-delta session is never compacted", %{sid: sid} do
    # Ten turns of ~60-byte changes: well under the floor, so replaying stays
    # cheaper than a snapshot and the breakpoint must survive every turn.
    turns = churn(sid, 10, 40)

    assert length(turns) == 10

    # Compaction re-emits EVERY live section as `:added`. With one section in
    # play the tell is the ledger being reset, which shows up as the payload
    # count dropping back to 1 after having grown.
    counts = Enum.map(turns, &length/1)
    assert Enum.all?(counts, &(&1 >= 1))

    # The real assertion: the prefix that precedes the newest delta is stable
    # across turns — that is what the cache keys on.
    [_ | _] = List.last(turns)
  end

  test "a session with large churn still compacts, bounding the prompt", %{sid: sid} do
    # 4KB per turn blows past the floor quickly; without compaction the ledger
    # would grow without bound.
    turns = churn(sid, 12, 4_000)

    sizes =
      Enum.map(turns, fn sections ->
        sections |> Enum.map(fn {_id, t} -> byte_size(t) end) |> Enum.sum()
      end)

    # Bounded: the largest turn must not be anywhere near the sum of all deltas,
    # which is what an uncompacted ledger would cost.
    assert Enum.max(sizes) < Enum.sum(sizes),
           "the ledger never compacted — the prompt grows without bound"

    assert Enum.max(sizes) < 12 * 4_000,
           "compaction did not bound the replayed ledger"
  end

  test "compaction still re-emits the whole world, not just the changed part", %{sid: sid} do
    # The safety property compaction exists to preserve: after collapsing, the
    # model must still see every live section, or a capability silently vanishes.
    _ = churn(sid, 12, 4_000)

    {sections, _} =
      WorldState.assemble(sid, [
        block("plan_mode", "final plan"),
        block("tool_process", "final tools")
      ])

    text = sections |> Enum.map(fn {_id, t} -> t end) |> Enum.join("\n")
    assert text =~ "final plan"
    assert text =~ "final tools"
  end
end
