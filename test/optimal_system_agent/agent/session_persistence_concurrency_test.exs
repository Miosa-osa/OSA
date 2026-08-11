defmodule OptimalSystemAgent.Agent.SessionPersistenceConcurrencyTest do
  @moduledoc """
  Defects 3 and 4: silent turn loss in the session record.

    * **Defect 3** — `save/3` installed the record with `File.rename!`, which is
      whole-file last-writer-wins. Two OSA OS processes (every `osa` invocation
      is its own BEAM) touching one session meant one side's turns were
      discarded with no error and no log.

    * **Defect 4** — `update_metadata/2` was a whole-record read-modify-write: it
      read `<id>.json`, merged `%{title: ...}` in, and wrote the WHOLE record
      back, `messages` included. A metadata update racing a turn save therefore
      restored a pre-turn snapshot of the transcript. That is a single-node race,
      hit constantly in practice because `MessageQueue` mirrors every queue
      mutation through `save_queue/2` → `update_metadata/2`.

  The tests below are deterministic — no sleeps, no timing assumptions. The
  interleaving test uses an explicit start barrier and message-passing joins, and
  the two structural tests need no concurrency at all because they pin the
  invariants the races violate.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence

  defp sessions_dir, do: Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "sessions")

  defp session_file(id) do
    Path.join(sessions_dir(), "#{Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")}.json")
  end

  defp msg(text), do: %{role: "user", content: text}

  defp contents(id) do
    {:ok, messages} = SessionPersistence.load(id)
    Enum.map(messages, & &1[:content])
  end

  setup do
    id = "osa_persist_conc_#{System.unique_integer([:positive])}"
    on_exit(fn -> SessionPersistence.delete(id) end)
    {:ok, id: id}
  end

  # ── Defect 4 ─────────────────────────────────────────────────────────

  describe "update_metadata/2 vs the transcript (defect 4)" do
    test "a metadata update does not rewrite the transcript at all", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1")])
      before = File.read!(session_file(id))

      :ok = SessionPersistence.update_metadata(id, %{title: "Renamed"})

      # THE bug, stated as an invariant: a metadata update that touches
      # `<id>.json` is a read-modify-write over `messages`, and a read-modify-
      # write over `messages` can lose a turn. The only way it cannot lose a
      # turn is by not writing that file.
      assert File.read!(session_file(id)) == before

      # ...while still actually recording the metadata.
      assert %{title: "Renamed"} = SessionPersistence.get_metadata(id)
      assert contents(id) == ["m1"]
    end

    test "queue mirroring does not rewrite the transcript either", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1")])
      before = File.read!(session_file(id))

      :ok = SessionPersistence.save_queue(id, ["queued-1", "queued-2"])

      assert File.read!(session_file(id)) == before
      assert SessionPersistence.load_queue(id) == ["queued-1", "queued-2"]
    end

    test "a metadata update interleaved with a turn save loses no messages", %{id: id} do
      # The lost update, driven in the exact losing order with no sleeps: a
      # metadata update that observed the session at T0 gets to write AFTER a
      # turn save landed at T1. `stale` is precisely what the old
      # read-modify-write held in memory across that window.
      :ok = SessionPersistence.save(id, [msg("m1")])
      path = session_file(id)
      stale = Jason.decode!(File.read!(path))

      # T1 — the turn save lands.
      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])

      # T2 — the metadata update writes. The old implementation merged its
      # fields into `stale` (messages included) and renamed the WHOLE record
      # back, so "m2" vanished. This asserts the property that makes that
      # impossible: what a metadata update writes is disjoint from the
      # transcript, so replaying its T0 view cannot reach `messages`.
      before = File.read!(path)
      :ok = SessionPersistence.update_metadata(id, %{title: "Renamed"})

      assert File.read!(path) == before,
             "update_metadata/2 rewrote the transcript; a stale view of " <>
               "#{inspect(stale["messages"])} can now clobber the saved turn"

      assert contents(id) == ["m1", "m2"]
      assert SessionPersistence.get_metadata(id).title == "Renamed"
    end

    test "sustained metadata updates interleaved with turn saves lose no messages", %{id: id} do
      turns = 40
      parent = self()

      # Explicit barrier: both workers block until every worker is registered and
      # the parent releases them, so the interleaving is real rather than
      # "whoever got scheduled first finished before the other started". No
      # sleeps anywhere — a regression fails, it does not flake.
      start = fn -> receive do: (:go -> :ok) end

      saver =
        spawn_link(fn ->
          send(parent, {:ready, self()})
          start.()

          Enum.each(1..turns, fn n ->
            :ok = SessionPersistence.save(id, Enum.map(1..n, &msg("m#{&1}")))
          end)

          send(parent, {:done, :saver})
        end)

      tagger =
        spawn_link(fn ->
          send(parent, {:ready, self()})
          start.()

          Enum.each(1..turns, fn n ->
            :ok = SessionPersistence.update_metadata(id, %{title: "t#{n}"})
          end)

          send(parent, {:done, :tagger})
        end)

      assert_receive {:ready, ^saver}, 5_000
      assert_receive {:ready, ^tagger}, 5_000
      send(saver, :go)
      send(tagger, :go)

      assert_receive {:done, :saver}, 30_000
      assert_receive {:done, :tagger}, 30_000

      # Every turn the saver committed must still be there. Under the old
      # whole-record read-modify-write, a tagger write landing after a turn save
      # reinstated the pre-turn message list and the transcript came back short.
      assert contents(id) == Enum.map(1..turns, &"m#{&1}")
      assert SessionPersistence.get_metadata(id).title =~ ~r/^t\d+$/
    end
  end

  # ── Defect 3 ─────────────────────────────────────────────────────────

  describe "save/3 vs a second OSA process (defect 3)" do
    test "a foreign writer's turns are merged, not silently discarded", %{id: id} do
      # This VM establishes its lineage.
      :ok = SessionPersistence.save(id, [msg("m1")])

      # A SECOND osa process saves its own view of the session. Reproduced
      # exactly as that process would leave the filesystem: a complete record
      # installed by rename, stamped with its own writer id and the next rev.
      record = Jason.decode!(File.read!(session_file(id)))

      foreign =
        record
        |> Map.put("messages", [
          %{"role" => "user", "content" => "m1"},
          %{"role" => "assistant", "content" => "from-other-process"}
        ])
        |> Map.put("message_count", 2)
        |> Map.put("rev", (record["rev"] || 0) + 1)
        |> Map.put("writer", "some-other-osa-vm")

      tmp = session_file(id) <> ".foreign"
      File.write!(tmp, Jason.encode!(foreign))
      File.rename!(tmp, session_file(id))

      # Now this VM saves its own next turn, derived from state it read BEFORE
      # the foreign write landed.
      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2-from-us")])

      kept = contents(id)

      # Neither side may be dropped. Old behaviour: ["m1", "m2-from-us"] — the
      # other process's turn gone, no error, no log.
      assert "from-other-process" in kept,
             "the concurrent process's turn was silently discarded: #{inspect(kept)}"

      assert "m2-from-us" in kept
      assert "m1" in kept
    end

    test "our own lineage may still shrink the list (compaction / rewind)", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2"), msg("m3")])

      # Compaction and rewind both legitimately replace the list with a SHORTER
      # one. Conflict detection must not resurrect what they pruned.
      :ok = SessionPersistence.save(id, [msg("summary")])

      assert contents(id) == ["summary"]
    end

    test "a session this VM has never read is overwritten, not merged", %{id: id} do
      # Honest boundary: with no observed revision there is no basis to call a
      # foreign write a conflict, so behaviour is unchanged from before.
      File.mkdir_p!(sessions_dir())

      File.write!(
        session_file(id),
        Jason.encode!(%{
          "session_id" => id,
          "messages" => [%{"role" => "user", "content" => "stale"}],
          "rev" => 7,
          "writer" => "an-older-osa-vm"
        })
      )

      :ok = SessionPersistence.save(id, [msg("fresh")])
      assert contents(id) == ["fresh"]
    end

    test "every record carries a monotonic rev and a writer id", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1")])
      first = Jason.decode!(File.read!(session_file(id)))

      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])
      second = Jason.decode!(File.read!(session_file(id)))

      assert is_integer(first["rev"])
      assert second["rev"] == first["rev"] + 1
      assert is_binary(second["writer"])
      assert second["writer"] == first["writer"]
    end
  end
end
