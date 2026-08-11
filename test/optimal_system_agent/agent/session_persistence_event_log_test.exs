defmodule OptimalSystemAgent.Agent.SessionPersistenceEventLogTest do
  @moduledoc """
  Durability defects in the two-log persistence, all of which end in the mutable
  transcript and the immutable event log disagreeing without anyone noticing.

    * **Cursor blind to interior edits.** The incremental-projection cursor
      validated only the FIRST and LAST message of the span it had already
      projected. An in-place rewrite of any message between them left both
      endpoints intact, so the fast path declared "pure append" and wrote only
      the tail — the edit never reached the event log. `micro_compact` has
      exactly that shape (it rewrites older tool results in place), so a prune
      recorded in `<id>.json` was absent from `<id>.updates.jsonl`, and an
      events-fallback recovery restored content the live session had dropped.

    * **Log read failing open.** A read error on the event log was coerced to
      "the log is empty", which turns the delta into "everything" and duplicates
      the whole transcript into the append-only log. Multiset identity — the
      thing that makes the design compaction-safe — makes that duplicate
      indistinguishable from legitimate repetition afterwards.

    * **Torn lines swallowed.** The skipped-record count was discarded at every
      call site, so torn records were silently re-appended.

    * **Recovery not establishing lineage.** `load/1`'s corruption-recovery path
      never recorded an observed revision, which disabled `save/3`'s
      merge-on-conflict for exactly the sessions that had just recovered.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.SessionPersistence

  defp sessions_dir, do: Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "sessions")
  defp safe(id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
  defp session_file(id), do: Path.join(sessions_dir(), "#{safe(id)}.json")
  defp updates_file(id), do: Path.join(sessions_dir(), "#{safe(id)}.updates.jsonl")
  defp cursor_file(id), do: updates_file(id) <> ".cursor"

  defp msg(text), do: %{role: "user", content: text}

  defp event_contents(id) do
    id |> SessionPersistence.load_events() |> Enum.map(&Map.get(&1, "content"))
  end

  defp root? do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out) == "0"
      _ -> false
    end
  end

  setup do
    id = "osa_persist_log_#{System.unique_integer([:positive])}"
    on_exit(fn -> SessionPersistence.delete(id) end)
    {:ok, id: id}
  end

  describe "projection cursor vs in-place edits" do
    test "an in-place rewrite of a MIDDLE message reaches the immutable log", %{id: id} do
      original = Enum.map(1..5, &msg("m#{&1}"))
      :ok = SessionPersistence.save(id, original)
      assert event_contents(id) == ["m1", "m2", "m3", "m4", "m5"]

      # Exactly the shape `Compactor.apply_step(:micro_compact, ...)` produces:
      # an older message's content is replaced in place. Same length, same head,
      # same tail — the two endpoints the cursor used to check are untouched.
      pruned = List.replace_at(original, 2, msg("m3-PRUNED"))
      :ok = SessionPersistence.save(id, pruned)

      events = event_contents(id)

      assert "m3-PRUNED" in events,
             "the in-place edit never reached the append-only log: #{inspect(events)}"

      # And the log stays append-only: nothing was removed.
      assert "m3" in events
    end

    test "a pure append still takes the fast path (no full-log rescan)", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])
      cursor_before = File.read!(cursor_file(id)) |> Jason.decode!()

      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2"), msg("m3")])
      cursor_after = File.read!(cursor_file(id)) |> Jason.decode!()

      assert cursor_after["msg_count"] == 3
      # Seqs stay dense and monotonic, i.e. the append was incremental rather
      # than a rebuild that renumbered everything.
      assert cursor_after["next_seq"] == cursor_before["next_seq"] + 1
      assert event_contents(id) == ["m1", "m2", "m3"]
    end
  end

  describe "event-log read failures" do
    test "an unreadable log aborts the append instead of duplicating the transcript", %{id: id} do
      if root?() do
        # root ignores the permission bits, so the failure cannot be constructed.
        assert true
      else
        :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])
        assert length(SessionPersistence.load_events(id)) == 2

        # Force the slow (full-diff) path, which is the one that read the log.
        File.rm!(cursor_file(id))

        # Write-only: the read fails with EACCES while the append itself would
        # still succeed — precisely the transient condition that used to make
        # `seen` empty and re-append the entire session.
        File.chmod!(updates_file(id), 0o222)

        log =
          capture_log(fn ->
            assert :ok = SessionPersistence.save(id, [msg("m1"), msg("m2"), msg("m3")])
          end)

        File.chmod!(updates_file(id), 0o644)

        assert event_contents(id) == ["m1", "m2"],
               "a failed log read duplicated the transcript into the append-only log"

        assert log =~ "could not read the immutable event log"
      end
    end

    test "torn records are reported, not silently re-appended in the dark", %{id: id} do
      :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])

      # Tear the last record, then force the slow path.
      contents = File.read!(updates_file(id))
      File.write!(updates_file(id), String.slice(contents, 0, byte_size(contents) - 20))
      File.rm!(cursor_file(id))

      log =
        capture_log(fn ->
          assert :ok = SessionPersistence.save(id, [msg("m1"), msg("m2")])
        end)

      assert log =~ "torn/unparseable record(s)"
      assert log =~ id

      on_exit(fn -> File.rm(updates_file(id) <> ".corrupt") end)
    end
  end

  describe "recovery establishes write lineage" do
    test "a session recovered from the event log still merges a concurrent writer", %{id: id} do
      File.mkdir_p!(sessions_dir())

      # A session whose transcript is corrupt but whose immutable log is intact.
      File.write!(
        updates_file(id),
        Enum.map_join(1..2, "", fn n ->
          Jason.encode!(%{
            "seq" => n - 1,
            "ts" => "2026-01-01T00:00:00Z",
            "hash" => "h#{n}",
            "msg" => %{"role" => "user", "content" => "m#{n}"}
          }) <> "\n"
        end)
      )

      File.write!(session_file(id), "{ this is not json")

      # Recovery path: rebuilds from the event log.
      assert {:ok, recovered} = SessionPersistence.load(id)
      assert Enum.map(recovered, & &1[:content]) == ["m1", "m2"]

      # A second OSA process now writes a healthy transcript of its own.
      File.write!(
        session_file(id),
        Jason.encode!(%{
          "session_id" => id,
          "messages" => [
            %{"role" => "user", "content" => "m1"},
            %{"role" => "assistant", "content" => "from-other-process"}
          ],
          "message_count" => 2,
          "rev" => 4,
          "writer" => "some-other-osa-vm"
        })
      )

      # We save our own view. Without a lineage recorded at recovery time this
      # took the plain-overwrite branch and the other process's turn vanished.
      :ok = SessionPersistence.save(id, recovered ++ [msg("m3-from-us")])

      {:ok, final} = SessionPersistence.load(id)
      kept = Enum.map(final, & &1[:content])

      assert "from-other-process" in kept,
             "a recovered session silently overwrote a concurrent writer: #{inspect(kept)}"

      assert "m3-from-us" in kept
    end
  end
end
