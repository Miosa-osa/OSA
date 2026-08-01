defmodule OptimalSystemAgent.Agent.SessionPersistenceCursorTest do
  @moduledoc """
  Tests for the `.updates.jsonl.cursor` projection state (unbounded-growth fix).

  The append-only event log stays the source of truth; the cursor sidecar makes
  it *incrementally projectable* so a per-turn save no longer re-reads and
  re-hashes the entire history (previously O(N) per turn / O(N²) per session).

  These tests assert the BOUND, not just the behaviour:

    * a steady-state turn appends exactly one line and reads none of the log,
    * per-turn cost does not scale with history length,

  plus that every cursor miss (absent, stale, corrupt, compaction, rewind)
  self-heals into the full-diff path without losing or duplicating an event.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence

  @dir Path.expand("~/.osa/sessions")

  defp safe(id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
  defp session_file(id), do: Path.join(@dir, "#{safe(id)}.json")
  defp updates_file(id), do: Path.join(@dir, "#{safe(id)}.updates.jsonl")
  defp cursor_file(id), do: updates_file(id) <> ".cursor"

  defp cleanup(id) do
    path = session_file(id)
    u = updates_file(id)

    Enum.each(
      [path, path <> ".corrupt", u, u <> ".lock", u <> ".corrupt", u <> ".cursor"],
      &File.rm/1
    )
  end

  defp line_count(path) do
    case File.read(path) do
      {:ok, c} -> c |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp convo(n), do: for(i <- 1..n, do: %{role: "user", content: "m#{i}"})

  setup do
    id = "osa_cursor_#{System.unique_integer([:positive])}"
    File.mkdir_p!(@dir)
    on_exit(fn -> cleanup(id) end)
    {:ok, id: id}
  end

  describe "cursor sidecar lifecycle" do
    test "a save writes a cursor next to the log", %{id: id} do
      refute File.exists?(cursor_file(id))
      assert :ok = SessionPersistence.save(id, convo(3))

      assert File.exists?(cursor_file(id))
      assert {:ok, %{"v" => 1, "msg_count" => 3, "next_seq" => 3}} =
               cursor_file(id) |> File.read!() |> Jason.decode()
    end

    test "the cursor is never mistaken for a session by list/1", %{id: id} do
      SessionPersistence.save(id, convo(2))
      ids = SessionPersistence.list(limit: 500) |> Enum.map(& &1.session_id)

      assert safe(id) in ids
      # Neither the log nor its cursor may surface as a resumable session.
      refute Enum.any?(ids, &String.ends_with?(&1, ".updates.jsonl"))
      refute Enum.any?(ids, &String.ends_with?(&1, ".updates.jsonl.cursor"))
      refute Enum.any?(ids, &String.ends_with?(&1, ".cursor"))
    end

    test "deleting the session retires the cursor", %{id: id} do
      SessionPersistence.save(id, convo(2))
      assert File.exists?(cursor_file(id))

      SessionPersistence.delete(id)
      refute File.exists?(cursor_file(id))
      refute File.exists?(updates_file(id))
    end
  end

  describe "the bound: a steady-state turn does not touch history" do
    test "an append-only turn writes exactly one line and re-reads nothing", %{id: id} do
      base = convo(40)
      assert :ok = SessionPersistence.save(id, base)
      assert line_count(updates_file(id)) == 40

      # Scramble every byte of the existing log while preserving its exact size
      # and line structure. The slow path would read this back, find 40
      # unparseable lines, and re-append all 40 messages. The fast path never
      # reads the log at all — so if the cursor is doing its job the log grows
      # by exactly the one new message.
      scrambled =
        updates_file(id)
        |> File.read!()
        |> String.replace(~r/[^\n]/, "x")

      File.write!(updates_file(id), scrambled)
      before_size = File.stat!(updates_file(id)).size

      assert :ok = SessionPersistence.save(id, base ++ [%{role: "assistant", content: "new"}])

      assert line_count(updates_file(id)) == 41,
             "steady-state turn must append 1 line, not re-project the whole log"

      assert File.stat!(updates_file(id)).size > before_size
    end

    test "N sequential turns append exactly N events", %{id: id} do
      Enum.reduce(1..60, [], fn i, acc ->
        msgs = acc ++ [%{role: "user", content: "turn #{i}"}]
        assert :ok = SessionPersistence.save(id, msgs)
        msgs
      end)

      assert line_count(updates_file(id)) == 60
      assert length(SessionPersistence.load_events(id)) == 60

      # Seqs stay dense and monotonic across every fast-path append.
      seqs =
        updates_file(id)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(Jason.decode!(&1) |> Map.fetch!("seq")))

      assert seqs == Enum.to_list(0..59)
    end

    # Deliberately NOT a wall-clock ratio across two history sizes.
    #
    # `save/3` rebuilds the whole mutable `<id>.json` transcript on EVERY turn:
    # `sanitize_messages/1` over all N, `merge_preserved_metadata/2` (which
    # reads and JSON-decodes the previous file), `Jason.encode/1` of all N, and
    # a full write. That is Θ(N) per turn by construction, and it dwarfs the
    # event-log append this cursor exists to bound — so end-to-end timing
    # measures the transcript rewrite, not the cursor.
    #
    # The previous version of this test asserted that growing history 10x cost
    # less than 6x more wall-clock. That ceiling sits BELOW the code's own O(N)
    # floor, so it only ever passed while fixed syscall overhead masked the
    # difference, and failed intermittently under a loaded full-suite run
    # (observed: 328us at 100 msgs vs 2390us at 1000 — a 7.3x that is the
    # expected ~10x attenuated by constant overhead, not a regression).
    #
    # The property that actually matters — the append path does not re-read or
    # re-project the log as history grows — is exact, so assert it exactly, at
    # 25x the history of the sibling case above.
    test "per-turn cost does not scale with history length" do
      sid = "osa_cursor_bench_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup(sid) end)

      base = convo(1000)
      assert :ok = SessionPersistence.save(sid, base)
      assert line_count(updates_file(sid)) == 1000

      assert {:ok, %{"msg_count" => 1000, "next_seq" => 1000}} =
               cursor_file(sid) |> File.read!() |> Jason.decode()

      # Same trap as the 40-message case, scaled up: destroy every byte of the
      # log while preserving its exact size and line structure. Any path that
      # reads history back finds 1000 unparseable lines and re-appends all of
      # them; the cursor fast path never opens the log for reading.
      scrambled =
        updates_file(sid)
        |> File.read!()
        |> String.replace(~r/[^\n]/, "x")

      File.write!(updates_file(sid), scrambled)

      assert :ok = SessionPersistence.save(sid, base ++ [%{role: "assistant", content: "new"}])

      assert line_count(updates_file(sid)) == 1001,
             "a turn against a 1000-message history must append exactly one event, " <>
               "not re-project the log"

      # And the projection state advanced by exactly one event, so the next turn
      # is O(1) too rather than silently having fallen back to the full diff.
      assert {:ok, %{"msg_count" => 1001, "next_seq" => 1001}} =
               cursor_file(sid) |> File.read!() |> Jason.decode()
    end
  end

  describe "cursor misses self-heal into the full diff" do
    test "a deleted cursor neither loses nor duplicates events", %{id: id} do
      base = convo(6)
      SessionPersistence.save(id, base)
      File.rm!(cursor_file(id))

      SessionPersistence.save(id, base ++ [%{role: "assistant", content: "after"}])

      contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      assert contents == Enum.map(1..6, &"m#{&1}") ++ ["after"]
      assert File.exists?(cursor_file(id))
    end

    test "a corrupt cursor falls back cleanly", %{id: id} do
      base = convo(4)
      SessionPersistence.save(id, base)
      File.write!(cursor_file(id), "{not json")

      SessionPersistence.save(id, base ++ [%{role: "assistant", content: "z"}])
      assert length(SessionPersistence.load_events(id)) == 5
    end

    test "a stale cursor (log appended behind our back) is detected by size", %{id: id} do
      base = convo(4)
      SessionPersistence.save(id, base)

      # Simulate a second writer appending an event we did not project.
      File.write!(
        updates_file(id),
        Jason.encode!(%{"seq" => 99, "ts" => "x", "hash" => "deadbeef", "msg" => %{"role" => "user", "content" => "other"}}) <> "\n",
        [:append]
      )

      SessionPersistence.save(id, base ++ [%{role: "assistant", content: "mine"}])

      contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      assert "other" in contents, "a foreign append must survive the next projection"
      assert "mine" in contents
      # The four base messages are still single copies — the size check forced a
      # multiset diff rather than blind re-appending.
      assert Enum.count(contents, &(&1 == "m1")) == 1
    end

    test "compaction is a cursor miss and the immutable log keeps everything", %{id: id} do
      full = convo(6)
      SessionPersistence.save(id, full)

      compacted = [%{role: "user", content: "[summary]"} | Enum.take(full, -2)]
      SessionPersistence.save(id, compacted)

      contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      assert Enum.map(1..6, &"m#{&1}") -- contents == []
      assert "[summary]" in contents
      assert Enum.count(contents, &(&1 == "m5")) == 1

      # And the session regrows on the fast path from the compacted list.
      SessionPersistence.save(id, compacted ++ [%{role: "assistant", content: "post"}])
      assert "post" in (SessionPersistence.load_events(id) |> Enum.map(& &1["content"]))
    end

    test "a rewind (shorter list) appends nothing", %{id: id} do
      full = convo(6)
      SessionPersistence.save(id, full)
      before = line_count(updates_file(id))

      SessionPersistence.save(id, Enum.take(full, 3))
      assert line_count(updates_file(id)) == before
    end

    test "duplicated content is still preserved as separate events", %{id: id} do
      SessionPersistence.save(id, [%{role: "user", content: "ok"}])

      SessionPersistence.save(id, [
        %{role: "user", content: "ok"},
        %{role: "user", content: "ok"}
      ])

      contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      assert contents == ["ok", "ok"]
    end
  end
end
