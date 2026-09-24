defmodule OptimalSystemAgent.Prefetch.CacheTest do
  @moduledoc """
  A prefetch cache that ever serves stale content is worse than no cache: the
  model would read a lie. So the filesystem-truth validation — not the plain
  hit/miss path — is what these tests are actually pinning down.

  The load-bearing cases are the ones where the file changes BEHIND the
  cache's back: a direct `File.write!/2`, never through `Prefetch.Engine` or
  any OSA tool. `put/5` refuses to cache a read that does not correspond to a
  stable, current filesystem state, and `get/1` re-validates on every lookup —
  either one alone would be a real correctness gap.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Prefetch.Cache

  @moduletag :tmp_dir

  setup do
    Cache.reset!()
    :ok
  end

  # Writes `content` to a fresh file under `dir`, stats it, and stores it —
  # the exact sequence `Prefetch.Engine.run_and_store/5` follows in
  # production (read, then stat, then put). Returns `{key, path}`.
  defp cache_a_real_file(dir, label, content) do
    path = Path.join(dir, "#{label}-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    stat = Cache.stat_snapshot(path)
    key = Cache.fingerprint("file_read", %{"path" => path})
    assert :ok = Cache.put(key, content, Cache.path_watch(path), stat, 1)
    {key, path}
  end

  test "miss on an unknown key" do
    key =
      Cache.fingerprint("file_read", %{"path" => "/nope/#{System.unique_integer([:positive])}"})

    assert Cache.get(key) == :miss
  end

  test "a stored value is served back with its recorded duration", %{tmp_dir: dir} do
    path = Path.join(dir, "x.txt")
    File.write!(path, "hello")
    stat = Cache.stat_snapshot(path)
    key = Cache.fingerprint("file_read", %{"path" => path})

    assert :ok = Cache.put(key, "hello", Cache.path_watch(path), stat, 42)
    assert {:hit, "hello", 42} = Cache.get(key)
  end

  test "fingerprint ignores loop-injected keys and key order" do
    a =
      Cache.fingerprint("file_read", %{
        "path" => "/tmp/x",
        "__session_id__" => "s1",
        "__tool_use_id__" => "t1"
      })

    b =
      Cache.fingerprint("file_read", %{
        "__session_id__" => "s2",
        "path" => "/tmp/x",
        "__tool_use_id__" => "t2"
      })

    assert a == b
  end

  test "fingerprint distinguishes different args" do
    a = Cache.fingerprint("file_read", %{"path" => "/tmp/x"})
    b = Cache.fingerprint("file_read", %{"path" => "/tmp/y"})
    refute a == b
  end

  describe "stat_snapshot/1" do
    test "returns mtime/size/inode for a real file", %{tmp_dir: dir} do
      path = Path.join(dir, "s.txt")
      File.write!(path, "abc")

      assert %{mtime: _, size: 3, inode: _} = Cache.stat_snapshot(path)
    end

    test "returns nil for a path that does not exist" do
      assert Cache.stat_snapshot("/nope/#{System.unique_integer([:positive])}") == nil
    end

    test "changes when the file's content (and therefore size) changes", %{tmp_dir: dir} do
      path = Path.join(dir, "s.txt")
      File.write!(path, "abc")
      before = Cache.stat_snapshot(path)

      File.write!(path, "a much longer replacement body")
      after_write = Cache.stat_snapshot(path)

      refute before == after_write
    end
  end

  describe "put/5 refuses a read that does not match the current filesystem state" do
    test "a stat that does not match what is on disk right now is refused", %{tmp_dir: dir} do
      path = Path.join(dir, "mismatch.txt")
      File.write!(path, "original")
      stale_stat = Cache.stat_snapshot(path)

      # The file changed AFTER the stat was taken but BEFORE put/5 runs —
      # exactly the read-to-store race the pre/post-stat protocol closes.
      File.write!(path, "changed before the put landed")

      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :stale = Cache.put(key, "original", Cache.path_watch(path), stale_stat, 1)
      assert Cache.get(key) == :miss
    end

    test "a stat for a file that no longer exists is refused", %{tmp_dir: dir} do
      path = Path.join(dir, "gone.txt")
      File.write!(path, "here")
      stat = Cache.stat_snapshot(path)
      File.rm!(path)

      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :stale = Cache.put(key, "here", Cache.path_watch(path), stat, 1)
      assert Cache.get(key) == :miss
    end

    test "a matching stat is stored successfully", %{tmp_dir: dir} do
      {key, _path} = cache_a_real_file(dir, "ok", "fine")
      assert {:hit, "fine", _} = Cache.get(key)
    end
  end

  describe "the racy-mtime guard (settle_seconds)" do
    # `config/test.exs` sets `prefetch_settle_seconds: 0` so every OTHER test
    # in this file can cache immediately after writing. These two put the
    # production default back to prove the guard the config override
    # otherwise hides: two writes within the same whole second can leave
    # `mtime`+`size`+`inode` all identical (Erlang's stat mtime is
    # whole-second-granular), so a file that was JUST written is refused
    # rather than risk caching a collision that has not happened yet.
    setup do
      prev = Application.get_env(:optimal_system_agent, :prefetch_settle_seconds)
      Application.put_env(:optimal_system_agent, :prefetch_settle_seconds, 1)

      on_exit(fn ->
        if prev do
          Application.put_env(:optimal_system_agent, :prefetch_settle_seconds, prev)
        else
          Application.delete_env(:optimal_system_agent, :prefetch_settle_seconds)
        end
      end)

      :ok
    end

    test "a file written THIS SECOND is refused, even with a perfectly matching stat", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "just-written.txt")
      File.write!(path, "brand new")
      stat = Cache.stat_snapshot(path)

      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :stale = Cache.put(key, "brand new", Cache.path_watch(path), stat, 1)
      assert Cache.get(key) == :miss
    end

    @tag timeout: 5_000
    test "a file whose mtime is safely in the past is cached normally", %{tmp_dir: dir} do
      path = Path.join(dir, "settled.txt")
      File.write!(path, "old enough")

      # A real wait, not a faked stat: this is exactly the condition being
      # tested (mtime genuinely more than a second in the past), and a
      # fabricated `mtime` that disagreed with the file's REAL current stat
      # would just fail the OTHER half of `put/5`'s check for an unrelated
      # reason.
      Process.sleep(1_100)
      stat = Cache.stat_snapshot(path)

      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :ok = Cache.put(key, "old enough", Cache.path_watch(path), stat, 1)
      assert {:hit, "old enough", _} = Cache.get(key)
    end
  end

  describe "get/1 re-validates against the filesystem on every lookup — the load-bearing case" do
    test "a file modified BEHIND THE CACHE'S BACK (a direct File.write, not through any tool) misses",
         %{tmp_dir: dir} do
      {key, path} = cache_a_real_file(dir, "behind-the-back", "original content")
      assert {:hit, "original content", _} = Cache.get(key)

      # This is the scenario the whole fix is about: nothing in OSA touched
      # this file. A user's editor, a formatter, `git checkout`, a build
      # step — modeled here as the simplest possible external writer, a bare
      # File.write!/2 that never goes near Prefetch.Engine or any tool.
      File.write!(path, "modified by something outside OSA entirely")

      assert Cache.get(key) == :miss

      # And the entry is gone, not just reported miss-and-kept: the next
      # lookup does a fresh disk read via the real tool, not a second stale
      # hit.
      assert :ets.lookup(:osa_prefetch_cache, key) == []
    end

    test "a file replaced (unlink + recreate) with byte-identical content still misses — inode changed",
         %{tmp_dir: dir} do
      path = Path.join(dir, "replaced-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "same bytes")
      # Model the settled state the real cache requires before it will store
      # a file (`prefetch_settle_seconds`, off in the test env): the original
      # was last written a few seconds ago. Linux can reuse the freed inode
      # for the recreated file, so the protection that holds on every
      # platform is the recreated file's NEW mtime, not the inode.
      File.touch!(path, System.os_time(:second) - 10)
      stat = Cache.stat_snapshot(path)
      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :ok = Cache.put(key, "same bytes", Cache.path_watch(path), stat, 1)

      # Many editors/atomic writers replace a file by writing a temp file and
      # renaming over the original rather than editing in place. That can
      # leave mtime AND size unchanged (same content, written fast enough to
      # land in the same mtime tick) while the inode changes — mtime/size
      # alone would miss this; comparing inode too is why it does not.
      File.rm!(path)
      File.write!(path, "same bytes")

      assert Cache.get(key) == :miss
    end

    test "an untouched file still hits after other unrelated activity", %{tmp_dir: dir} do
      {key, _path} = cache_a_real_file(dir, "untouched", "steady")
      # Unrelated filesystem churn elsewhere must not affect this entry.
      other = Path.join(dir, "noise.txt")
      File.write!(other, "noise")
      File.write!(other, "more noise")

      assert {:hit, "steady", _} = Cache.get(key)
    end

    test "a file deleted behind the cache's back misses" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "deleteme-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "temporary")
      stat = Cache.stat_snapshot(path)
      key = Cache.fingerprint("file_read", %{"path" => path})
      assert :ok = Cache.put(key, "temporary", Cache.path_watch(path), stat, 1)

      File.rm!(path)

      assert Cache.get(key) == :miss
    end
  end

  test "invalidate_path drops an entry watching that exact path (proactive optimization)", %{
    tmp_dir: dir
  } do
    {key, path} = cache_a_real_file(dir, "watched", "body")
    assert {:hit, _, _} = Cache.get(key)

    Cache.invalidate_path(path)

    assert Cache.get(key) == :miss
  end

  test "invalidate_path leaves an unrelated path's entry alone", %{tmp_dir: dir} do
    {key_a, path_a} = cache_a_real_file(dir, "a", "a-body")
    {key_b, _path_b} = cache_a_real_file(dir, "b", "b-body")

    Cache.invalidate_path(path_a)

    assert Cache.get(key_a) == :miss
    assert {:hit, "b-body", _} = Cache.get(key_b)
  end

  test "invalidate_all drops everything", %{tmp_dir: dir} do
    {key_a, _} = cache_a_real_file(dir, "c", "c-body")
    {key_b, _} = cache_a_real_file(dir, "d", "d-body")

    Cache.invalidate_all()

    assert Cache.get(key_a) == :miss
    assert Cache.get(key_b) == :miss
  end

  test "an entry older than the configured TTL is evicted on read even though the file is unchanged",
       %{tmp_dir: dir} do
    prev = Application.get_env(:optimal_system_agent, :prefetch_cache_ttl_ms)
    Application.put_env(:optimal_system_agent, :prefetch_cache_ttl_ms, 10)

    on_exit(fn ->
      if prev do
        Application.put_env(:optimal_system_agent, :prefetch_cache_ttl_ms, prev)
      else
        Application.delete_env(:optimal_system_agent, :prefetch_cache_ttl_ms)
      end
    end)

    {key, _path} = cache_a_real_file(dir, "ttl", "expiring")

    Process.sleep(20)

    assert Cache.get(key) == :miss
  end
end
