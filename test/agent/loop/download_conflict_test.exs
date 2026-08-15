defmodule OptimalSystemAgent.Agent.Loop.DownloadConflictTest do
  @moduledoc """
  `download` was marked `concurrency_safe? true` on the strength of a comment
  that said "multiple downloads to *different* paths are safe" — the one claim a
  PER-CALL predicate structurally cannot make, since it never sees the other
  call. Two downloads to one path were dispatched together: a read-modify-write
  race in which the loser is silent and both calls report success. That is the
  same hazard as the `file_edit`-against-itself bug fixed in `05b22c57`, on a
  different tool.

  These tests pin BOTH halves of the fix, because either alone would be a
  regression:

    * two downloads to ONE path must not run at the same time, asserted on the
      final file contents and on the event ordering — not on "it didn't crash";
    * two downloads to DIFFERENT paths must still run at the same time, which
      is the parallel win that simply forcing `concurrency_safe? false` would
      have thrown away.

  The executor is injected rather than real: the point under test is the
  DISPATCH decision, and a test that reached the network would be testing
  something else (and would be flaky).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator

  # A read-modify-write against the call's declared path, with a real window
  # between the read and the write. Run concurrently against one path, the
  # second writer clobbers the first and one marker never appears.
  defmodule RmwExecutor do
    @moduledoc false
    def execute_tool_call(tc, state) do
      # Resolve exactly the way `Download.Handler.resolve_path/1` does, so a
      # relative call in the test writes where the real tool would write.
      raw = tc.arguments["path"]

      path =
        if String.starts_with?(raw, ["~", "/"]),
          do: Path.expand(raw),
          else:
            Path.expand(
              Path.join(
                OptimalSystemAgent.Tools.Builtins.Download.Constants.workspace_root(),
                raw
              )
            )

      pid = Map.get(state, :test_pid)
      if pid, do: send(pid, {:started, tc.id})

      body = File.read!(path)
      Process.sleep(Map.get(state, :hold_ms, 80))
      File.write!(path, body <> tc.arguments["marker"] <> "\n")

      if pid, do: send(pid, {:finished, tc.id})
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "ok"}, "ok"}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_dl_conflict_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp dl(id, path, marker),
    do: %{
      id: id,
      name: "download",
      arguments: %{"url" => "https://x/#{id}", "path" => path, "marker" => marker}
    }

  # `assert_receive` skips non-matching messages, so a run of them proves
  # nothing about ordering. Drain in arrival order instead.
  defp event_sequence(n) do
    for _ <- 1..n do
      receive do
        {tag, id} -> {tag, id}
      after
        5_000 -> flunk("timed out waiting for tool event")
      end
    end
  end

  describe "two downloads to ONE path" do
    test "neither write is lost", %{dir: dir} do
      path = Path.join(dir, "collide.bin")
      File.write!(path, "")
      state = %{session_id: "test", test_pid: self()}

      ToolOrchestrator.dispatch(
        [dl("d1", path, "FIRST"), dl("d2", path, "SECOND")],
        state,
        executor: RmwExecutor
      )

      final = File.read!(path)
      assert final =~ "FIRST", "the first download was clobbered by the second"
      assert final =~ "SECOND", "the second download was clobbered by the first"
    end

    test "they do not overlap in time", %{dir: dir} do
      path = Path.join(dir, "ordering.bin")
      File.write!(path, "")
      state = %{session_id: "test", test_pid: self()}

      ToolOrchestrator.dispatch(
        [dl("d1", path, "A"), dl("d2", path, "B")],
        state,
        executor: RmwExecutor
      )

      assert event_sequence(4) == [
               {:started, "d1"},
               {:finished, "d1"},
               {:started, "d2"},
               {:finished, "d2"}
             ]
    end

    test "a RELATIVE and an ABSOLUTE name for one target still collide", %{dir: dir} do
      # Normalisation is what makes the comparison honest. `download` roots a
      # relative path at ~/.osa/workspace, so that is where the collision has
      # to be detected — spelling, not string equality.
      root = Path.expand("~/.osa/workspace")
      File.mkdir_p!(root)
      name = "osa_conflict_#{System.unique_integer([:positive])}.bin"
      abs = Path.join(root, name)
      File.write!(abs, "")
      on_exit(fn -> File.rm(abs) end)

      _ = dir
      state = %{session_id: "test", test_pid: self()}

      ToolOrchestrator.dispatch(
        [dl("d1", name, "REL"), dl("d2", abs, "ABS")],
        state,
        executor: RmwExecutor
      )

      final = File.read!(abs)
      assert final =~ "REL"
      assert final =~ "ABS"
    end
  end

  describe "two downloads to DIFFERENT paths" do
    test "still run in parallel", %{dir: dir} do
      a = Path.join(dir, "a.bin")
      b = Path.join(dir, "b.bin")
      File.write!(a, "")
      File.write!(b, "")
      state = %{session_id: "test", test_pid: self(), hold_ms: 150}

      started = System.monotonic_time(:millisecond)

      ToolOrchestrator.dispatch(
        [dl("d1", a, "A"), dl("d2", b, "B")],
        state,
        executor: RmwExecutor
      )

      elapsed = System.monotonic_time(:millisecond) - started
      seq = event_sequence(4)

      # Both announce a start before either finishes. That is the property, and
      # it is the one a blanket `concurrency_safe? false` would have destroyed.
      assert Enum.take(seq, 2) |> Enum.map(&elem(&1, 0)) == [:started, :started],
             "disjoint downloads were serialised: #{inspect(seq)}"

      assert elapsed < 290, "disjoint downloads took #{elapsed}ms — serialised"
    end
  end

  describe "the batch as a whole" do
    test "a colliding pair serialises without stalling the disjoint third", %{dir: dir} do
      shared = Path.join(dir, "shared.bin")
      other = Path.join(dir, "other.bin")
      File.write!(shared, "")
      File.write!(other, "")
      state = %{session_id: "test", test_pid: self(), hold_ms: 60}

      ToolOrchestrator.dispatch(
        [dl("s1", shared, "S1"), dl("o1", other, "O1"), dl("s2", shared, "S2")],
        state,
        executor: RmwExecutor
      )

      assert File.read!(shared) =~ "S1"
      assert File.read!(shared) =~ "S2"
      assert File.read!(other) =~ "O1"

      seq = event_sequence(6)
      # s1 and o1 are disjoint and share the first batch; s2 collides with s1
      # and waits for it.
      assert Enum.take(seq, 2) |> Enum.map(&elem(&1, 0)) == [:started, :started]
      assert {:started, "s2"} in Enum.drop(seq, 2)

      s1_done = Enum.find_index(seq, &(&1 == {:finished, "s1"}))
      s2_start = Enum.find_index(seq, &(&1 == {:started, "s2"}))
      assert s1_done < s2_start, "s2 started before s1 finished: #{inspect(seq)}"
    end
  end
end
