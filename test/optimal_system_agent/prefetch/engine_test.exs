defmodule OptimalSystemAgent.Prefetch.EngineTest do
  @moduledoc """
  End-to-end proof that the pipeline this whole feature depends on actually
  connects: an edit fires background candidates, one of them lands in the
  cache without the model ever asking, and `ToolExecutor`'s own lookup path
  serves it as an instant hit. A unit test on each stage in isolation would
  not catch the wiring between them coming apart.

  The load-bearing describe block is "stale reads from outside OSA": a file
  changing via a bare `File.write!/2` — never through `Engine.observe_tool_result/4`,
  never through any tool — must still be caught. `Prefetch.Cache` is what
  actually enforces that (see its own tests for the unit-level proof); these
  tests prove the guarantee survives all the way through the path
  `Agent.Loop.ToolExecutor` actually calls, `Engine.lookup/2`.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Prefetch.Cache
  alias OptimalSystemAgent.Prefetch.Engine
  alias OptimalSystemAgent.Workspace.Cwd

  @moduletag :tmp_dir

  setup do
    case Process.whereis(Engine) do
      nil -> start_supervised!(Engine)
      _ -> :ok
    end

    Cache.reset!()
    :ok
  end

  setup %{tmp_dir: dir} do
    session_id = "prefetch-test-#{System.unique_integer([:positive])}"
    Cwd.put_session_dir(session_id, dir)
    on_exit(fn -> Cwd.drop_session_dir(session_id) end)
    {:ok, session_id: session_id}
  end

  # Bounded poll instead of a fixed sleep: the pipeline is a background Task,
  # so its completion time is not deterministic, but it is always well under
  # this bound on a healthy run — a real hang should fail the test, not hang
  # it forever.
  defp eventually(fun, tries \\ 50) do
    if fun.() do
      true
    else
      if tries <= 0 do
        false
      else
        Process.sleep(20)
        eventually(fun, tries - 1)
      end
    end
  end

  # Writes `content` to a fresh real file under `dir` and stores it in the
  # cache exactly as `Prefetch.Engine.run_and_store/5` would (stat, then
  # put) — `Cache.put/5` refuses anything whose stat does not match the
  # filesystem right now, so a manually-inserted fixture has to be real.
  defp put_manual(dir, label, content) do
    path = Path.join(dir, "#{label}-#{System.unique_integer([:positive])}.ex")
    File.write!(path, content)
    stat = Cache.stat_snapshot(path)
    key = Cache.fingerprint("file_read", %{"path" => path})
    assert :ok = Cache.put(key, content, Cache.path_watch(path), stat, 3)
    {key, path}
  end

  test "lookup/2 is a plain miss for a key nothing ever fetched" do
    assert Engine.lookup("file_read", %{"path" => "/tmp/definitely-not-cached"}) == :miss
  end

  test "lookup/2 hits once the cache holds an entry for the same args", %{tmp_dir: dir} do
    {_key, path} = put_manual(dir, "manual", "manual body")
    assert Engine.lookup("file_read", %{"path" => path}) == {:hit, "manual body"}
  end

  test "a successful write fires sibling and test-file prefetches that land in the cache",
       %{tmp_dir: dir, session_id: sid} do
    lib = Path.join(dir, "lib/thing.ex")
    sibling = Path.join(dir, "lib/other.ex")
    test_file = Path.join(dir, "test/thing_test.exs")

    File.mkdir_p!(Path.dirname(lib))
    File.mkdir_p!(Path.dirname(test_file))
    File.write!(lib, "defmodule Thing do\nend\n")
    File.write!(sibling, "defmodule Other do\nend\n")
    File.write!(test_file, "defmodule ThingTest do\nend\n")

    Engine.observe_tool_result("file_edit", %{"path" => lib}, true, sid)

    sibling_hit? = fn -> Engine.lookup("file_read", %{"path" => sibling}) != :miss end
    test_hit? = fn -> Engine.lookup("file_read", %{"path" => test_file}) != :miss end

    assert eventually(sibling_hit?), "sibling was never prefetched into the cache"
    assert eventually(test_hit?), "test file was never prefetched into the cache"

    {:hit, body} = Engine.lookup("file_read", %{"path" => sibling})
    assert body =~ "Other"

    # The `fired` counter is what a turn-summary readout leans on to say
    # "prefetch attempted N calls this turn" — it must actually accumulate,
    # not just the hits/misses `lookup/2` records.
    assert eventually(fn -> Engine.turn_stats(sid).fired > 0 end),
           "fired count never incremented for a candidate that was actually spawned"
  end

  test "a real ToolExecutor-shaped lookup skips the disk on a hit", %{
    tmp_dir: dir,
    session_id: sid
  } do
    {_key, path} = put_manual(dir, "already-read", "defmodule AlreadyRead do\nend\n")

    # This is the exact shape ToolExecutor.execute_tool/2 calls lookup/2 with —
    # the loop's injected keys included, to prove the fingerprint really is
    # blind to them.
    enriched = %{"path" => path, "__session_id__" => sid, "__tool_use_id__" => "tu_1"}
    assert {:hit, content} = Engine.lookup("file_read", enriched)
    assert content =~ "AlreadyRead"
  end

  test "an OSA edit invalidates its own cached read, so the next lookup goes back to disk",
       %{tmp_dir: dir, session_id: sid} do
    {_key, path} = put_manual(dir, "mutable", "defmodule Mutable do\n  def v, do: 1\nend\n")

    assert Engine.lookup("file_read", %{"path" => path}) != :miss

    # The model's own edit lands, going through the tool pipeline this time
    # (unlike the "behind the cache's back" tests below).
    File.write!(path, "defmodule Mutable do\n  def v, do: 2\nend\n")
    Engine.observe_tool_result("file_edit", %{"path" => path}, true, sid)

    assert eventually(fn -> Engine.lookup("file_read", %{"path" => path}) == :miss end),
           "the edited file's cache entry was never invalidated"
  end

  describe "stale reads from outside OSA — the file changes and nothing tells the cache" do
    test "a file modified via a bare File.write! (no tool, no Engine call) misses on lookup",
         %{tmp_dir: dir} do
      {_key, path} = put_manual(dir, "external-edit", "original from disk")
      assert {:hit, "original from disk"} = Engine.lookup("file_read", %{"path" => path})

      # Models the user's editor, a formatter, `git checkout`, a build tool,
      # or any other process OSA does not instrument — the ONLY action here
      # is the write itself. No Engine.observe_tool_result, no invalidate
      # call, nothing.
      File.write!(path, "changed by something OSA never saw")

      assert Engine.lookup("file_read", %{"path" => path}) == :miss
    end

    test "after the miss, a real (non-cached) read returns the FRESH content",
         %{tmp_dir: dir, session_id: sid} do
      {_key, path} = put_manual(dir, "external-edit-fresh", "stale cached body")
      assert {:hit, "stale cached body"} = Engine.lookup("file_read", %{"path" => path})

      File.write!(path, "the real, current content on disk")
      assert Engine.lookup("file_read", %{"path" => path}) == :miss

      # `ToolExecutor` reacts to `:miss` by dispatching the REAL tool — proven
      # here directly against `ReadOnlyTools`, the exact function the real
      # dispatch path and the prefetch engine both funnel through, so a real
      # (uncached) read is demonstrably the fresh file, not the stale entry
      # that was just evicted.
      assert {:ok, fresh} =
               OptimalSystemAgent.Prefetch.ReadOnlyTools.run(
                 "file_read",
                 %{"path" => path},
                 sid
               )

      assert fresh =~ "the real, current content on disk"
      refute fresh =~ "stale cached body"
    end

    test "a directory listing changes behind the cache's back and misses on the next lookup",
         %{tmp_dir: dir, session_id: sid} do
      target = Path.join(dir, "listed")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "one.txt"), "x")

      {:ok, before} =
        OptimalSystemAgent.Prefetch.ReadOnlyTools.run("dir_list", %{"path" => target}, sid)

      stat = Cache.stat_snapshot(target)
      key = Cache.fingerprint("dir_list", %{"path" => target})
      assert :ok = Cache.put(key, before, Cache.path_watch(target), stat, 2)
      assert {:hit, ^before} = Engine.lookup("dir_list", %{"path" => target})

      # A file dropped into the directory from outside OSA — no tool call,
      # no Engine notification — changes the directory's own mtime.
      File.write!(Path.join(target, "two.txt"), "y")

      assert Engine.lookup("dir_list", %{"path" => target}) == :miss
    end

    test "a repeated external write keeps missing — the cache never re-latches onto stale bytes",
         %{tmp_dir: dir} do
      {_key, path} = put_manual(dir, "repeated-external", "version one of the content")

      File.write!(path, "version two, a different length")
      assert Engine.lookup("file_read", %{"path" => path}) == :miss

      # Nothing re-populates the cache on its own after a miss — confirms the
      # entry was actually deleted, not merely reported stale-but-kept.
      File.write!(path, "version three, yet another length again")
      assert Engine.lookup("file_read", %{"path" => path}) == :miss
    end
  end

  test "a repo-wide write invalidates unrelated cached entries too", %{
    tmp_dir: dir,
    session_id: sid
  } do
    {key, _path} = put_manual(dir, "unrelated", "unrelated body")

    Engine.observe_tool_result("git", %{"command" => "commit -m x"}, true, sid)

    assert eventually(fn -> Cache.get(key) == :miss end)
  end

  test "a failed write never invalidates or fires anything", %{tmp_dir: dir, session_id: sid} do
    {_key, path} = put_manual(dir, "untouched", "defmodule Untouched do\nend\n")

    Engine.observe_tool_result("file_edit", %{"path" => path}, false, sid)

    # Give any (wrongly-fired) background work a moment, then assert the
    # entry survived untouched.
    Process.sleep(50)
    assert Engine.lookup("file_read", %{"path" => path}) != :miss
  end

  test "end_turn/1 emits a telemetry summary and resets the session's counters",
       %{tmp_dir: dir, session_id: sid} do
    test_pid = self()

    :telemetry.attach(
      "prefetch-engine-test-#{sid}",
      [:osa, :prefetch, :turn],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:prefetch_turn, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("prefetch-engine-test-#{sid}") end)

    {_key, path} = put_manual(dir, "turn-stat", "body")

    # One hit, one miss this "turn".
    assert Engine.lookup("file_read", %{"path" => path, "__session_id__" => sid}) != :miss

    assert Engine.lookup("file_read", %{"path" => "/tmp/never-cached", "__session_id__" => sid}) ==
             :miss

    Engine.end_turn(sid)

    assert_receive {:prefetch_turn, measurements, metadata}, 1_000
    assert measurements.hits == 1
    assert measurements.misses == 1
    assert measurements.time_saved_ms == 3
    assert metadata.hit_rate == 0.5
    assert metadata.session_id == sid

    stats = Engine.turn_stats(sid)
    assert stats.hits == 0
    assert stats.misses == 0
  end
end
