defmodule OptimalSystemAgent.Agent.SessionPersistenceTwoLogTest do
  @moduledoc """
  Tests for two-log session persistence (P1 in docs/steal-list.md):

    * an IMMUTABLE append-only `<id>.updates.jsonl` event log alongside the
      MUTABLE compaction-pruned `<id>.json` transcript,
    * self-healing, locked appends (torn-tail heal),
    * corruption-tolerant loads (skip + quarantine, never fatal),
    * compaction rewrites the mutable transcript but NEVER the immutable log,
    * existing resume (save -> load) is preserved.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Agent.SessionPersistence.Jsonl

  @dir Path.expand("~/.osa/sessions")

  defp session_file(id) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    Path.join(@dir, "#{safe}.json")
  end

  defp updates_file(id) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    Path.join(@dir, "#{safe}.updates.jsonl")
  end

  defp cleanup(id) do
    path = session_file(id)

    Enum.each(
      [
        path,
        path <> ".corrupt",
        updates_file(id),
        updates_file(id) <> ".lock",
        updates_file(id) <> ".corrupt"
      ],
      &File.rm/1
    )
  end

  setup do
    id = "osa_two_log_#{System.unique_integer([:positive])}"
    File.mkdir_p!(@dir)
    on_exit(fn -> cleanup(id) end)
    {:ok, id: id}
  end

  # ── Storage submodule: durable, self-healing append ──────────────────

  describe "Jsonl.append/2 durability + torn-tail self-heal" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "osa_jsonl_#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn ->
        Enum.each([tmp, tmp <> ".lock", tmp <> ".corrupt"], &File.rm/1)
      end)

      {:ok, tmp: tmp}
    end

    test "appends are durable and read back in order", %{tmp: tmp} do
      assert :ok = Jsonl.append(tmp, [%{"seq" => 0, "v" => "a"}])
      assert :ok = Jsonl.append(tmp, [%{"seq" => 1, "v" => "b"}, %{"seq" => 2, "v" => "c"}])

      assert {:ok, records, 0} = Jsonl.read(tmp)
      assert Enum.map(records, & &1["v"]) == ["a", "b", "c"]
      # No lock left behind after a clean append.
      refute File.exists?(tmp <> ".lock")
    end

    test "a torn tail (no trailing newline) is healed and isolated to one line", %{tmp: tmp} do
      assert :ok = Jsonl.append(tmp, [%{"seq" => 0, "v" => "first"}])

      # Simulate a crash mid-append: a partial record with NO trailing newline.
      File.write!(tmp, ~s({"seq":1,"v":"tor), [:append])

      # The next append must heal the torn tail (prepend \n) so the partial line
      # is terminated as its own single corrupt line, not merged with the new one.
      assert :ok = Jsonl.append(tmp, [%{"seq" => 2, "v" => "after"}])

      assert {:ok, records, skipped} = Jsonl.read(tmp)
      # Exactly one line (the torn partial) is unparseable.
      assert skipped == 1
      # Both good records survive — the torn write did NOT corrupt them.
      values = Enum.map(records, & &1["v"])
      assert "first" in values
      assert "after" in values
      # Quarantine copy was written on first detected corruption.
      assert File.exists?(tmp <> ".corrupt")
    end
  end

  describe "Jsonl.read/1 corruption tolerance" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "osa_jsonl_c_#{System.unique_integer([:positive])}.jsonl")
      on_exit(fn -> Enum.each([tmp, tmp <> ".corrupt"], &File.rm/1) end)
      {:ok, tmp: tmp}
    end

    test "one corrupt line is skipped + quarantined, never fatal", %{tmp: tmp} do
      # A good line, a garbage line, another good line.
      File.write!(tmp, ~s({"seq":0,"v":"a"}\n{not valid json\n{"seq":2,"v":"c"}\n))

      assert {:ok, records, 1} = Jsonl.read(tmp)
      assert Enum.map(records, & &1["v"]) == ["a", "c"]
      assert File.exists?(tmp <> ".corrupt")
      # Quarantine is written once and preserves the ORIGINAL raw bytes.
      assert File.read!(tmp <> ".corrupt") =~ "not valid json"
    end

    test "a missing file is an empty log, not an error", %{tmp: tmp} do
      assert {:ok, [], 0} = Jsonl.read(tmp)
    end
  end

  # ── Integration through SessionPersistence.save/3 ────────────────────

  describe "save/3 maintains the immutable event log" do
    test "save appends new messages to the immutable log", %{id: id} do
      convo = [
        %{role: "user", content: "one"},
        %{role: "assistant", content: "two"}
      ]

      assert :ok = SessionPersistence.save(id, convo)
      assert File.exists?(updates_file(id))
      assert SessionPersistence.event_count(id) == 2

      events = SessionPersistence.load_events(id)
      assert Enum.map(events, & &1["content"]) == ["one", "two"]
    end

    test "a growing conversation only appends the new tail (no dup of prior turns)", %{id: id} do
      SessionPersistence.save(id, [%{role: "user", content: "q1"}])
      SessionPersistence.save(id, [%{role: "user", content: "q1"}, %{role: "assistant", content: "a1"}])

      SessionPersistence.save(id, [
        %{role: "user", content: "q1"},
        %{role: "assistant", content: "a1"},
        %{role: "user", content: "q2"}
      ])

      assert SessionPersistence.event_count(id) == 3

      contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      assert contents == ["q1", "a1", "q2"]
    end

    test "legitimately duplicated content is preserved as distinct events", %{id: id} do
      SessionPersistence.save(id, [%{role: "user", content: "ok"}])
      # Second identical "ok" in a later turn must NOT be collapsed away.
      SessionPersistence.save(id, [%{role: "user", content: "ok"}, %{role: "user", content: "ok"}])

      assert SessionPersistence.event_count(id) == 2
    end
  end

  describe "compaction rewrites the mutable transcript but never the immutable log" do
    test "a shorter (compacted) save leaves updates.jsonl intact", %{id: id} do
      full = [
        %{role: "user", content: "u1"},
        %{role: "assistant", content: "a1"},
        %{role: "user", content: "u2"},
        %{role: "assistant", content: "a2"},
        %{role: "user", content: "u3"}
      ]

      assert :ok = SessionPersistence.save(id, full)
      assert SessionPersistence.event_count(id) == 5

      # Compaction: the mutable list is replaced with a summary + recent tail.
      compacted = [
        %{role: "system", content: "[summary of u1..a2]"},
        %{role: "user", content: "u3"}
      ]

      assert :ok = SessionPersistence.save(id, compacted)

      # Mutable transcript reflects the compaction (shorter).
      assert {:ok, restored} = SessionPersistence.load(id)
      assert length(restored) == 2

      # Immutable log NEVER loses the pre-compaction events. The summary is a
      # new event (appended); every original message is still present.
      event_contents = SessionPersistence.load_events(id) |> Enum.map(& &1["content"])
      for c <- ["u1", "a1", "u2", "a2", "u3"], do: assert(c in event_contents)
      assert "[summary of u1..a2]" in event_contents
      # 5 originals + 1 summary; u3 already present so not re-appended.
      assert SessionPersistence.event_count(id) == 6
    end
  end

  describe "existing resume path is preserved (back-compat)" do
    test "save -> find_latest_for_dir -> load still restores turns", %{id: id} do
      dir = @dir

      convo = [
        %{role: "user", content: "first question"},
        %{role: "assistant", content: "first answer"}
      ]

      assert :ok = SessionPersistence.save(id, convo, dir)
      assert SessionPersistence.find_latest_for_dir(dir) == id

      assert {:ok, restored} = SessionPersistence.load(id)
      assert length(restored) == 2
      [u1 | _] = restored
      assert (u1[:role] || u1["role"]) == "user"
      assert (u1[:content] || u1["content"]) == "first question"
    end

    test "a session with no event log (pre-feature) loads fine and reports 0 events", %{id: id} do
      # Simulate an old on-disk record: only <id>.json exists, no updates.jsonl.
      File.write!(
        session_file(id),
        Jason.encode!(%{
          "session_id" => id,
          "messages" => [%{"role" => "user", "content" => "legacy"}]
        })
      )

      assert {:ok, [restored]} = SessionPersistence.load(id)
      assert (restored[:content] || restored["content"]) == "legacy"
      refute File.exists?(updates_file(id))
      assert SessionPersistence.load_events(id) == []
      assert SessionPersistence.event_count(id) == 0
    end
  end

  describe "delete/1 removes both logs" do
    test "delete cleans the mutable transcript and the immutable log + sidecars", %{id: id} do
      SessionPersistence.save(id, [%{role: "user", content: "x"}])
      assert File.exists?(session_file(id))
      assert File.exists?(updates_file(id))

      SessionPersistence.delete(id)

      refute File.exists?(session_file(id))
      refute File.exists?(updates_file(id))
      refute File.exists?(updates_file(id) <> ".corrupt")
    end
  end
end
