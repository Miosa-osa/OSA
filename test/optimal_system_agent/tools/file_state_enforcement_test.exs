defmodule OptimalSystemAgent.Tools.FileStateEnforcementTest do
  @moduledoc """
  Read-before-edit + stale-write enforcement (P0-1) and its integration with the
  file_read / file_edit / file_write / multi_file_edit handlers.

  Enforcement is session-scoped: these tests drive the handlers with a concrete
  (non-sentinel) session id so the guard is active. The `nil`/`"test"` sentinel
  sessions used by the flat compat shims are exempt and covered by their own
  test at the bottom.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileWrite.Handler, as: FileWrite
  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler, as: MultiFileEdit
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    sid = "fs-enforce-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_fs_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, sid: sid, path: path}
  end

  defp edit(path, old, new, ctx),
    do: FileEdit.execute(%{"path" => path, "old_string" => old, "new_string" => new}, ctx)

  describe "read-before-edit" do
    test "read then edit passes", %{ctx: ctx, path: path} do
      File.write!(path, "alpha\nbeta\ngamma\n")

      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      result = edit(path, "beta", "BETA", ctx)
      assert :ok == elem(result, 0)
      assert File.read!(path) == "alpha\nBETA\ngamma\n"
    end

    test "edit without a prior read fails with a read-first directive", %{ctx: ctx, path: path} do
      # File exists on disk but was never read *through file_read this session*.
      File.write!(path, "alpha\nbeta\ngamma\n")

      assert {:error, msg} = edit(path, "beta", "BETA", ctx)
      assert msg =~ "must read"
      assert msg =~ "file_read"
      # File is untouched — the edit was rejected before any write.
      assert File.read!(path) == "alpha\nbeta\ngamma\n"
    end

    test "file_write overwrite of an unread existing file fails", %{ctx: ctx, path: path} do
      File.write!(path, "original\n")

      assert {:error, msg} = FileWrite.execute(%{"path" => path, "content" => "clobbered\n"}, ctx)
      assert msg =~ "must read"
      assert File.read!(path) == "original\n"
    end
  end

  describe "stale-write detection" do
    test "edit fails when the file changed on disk since it was read", %{ctx: ctx, path: path} do
      File.write!(path, "alpha\nbeta\ngamma\n")
      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      # Simulate a linter/user/other-agent modifying the file underneath us:
      # both content (size) and mtime change.
      File.write!(path, "alpha\nbeta\ngamma\nDELTA-added-by-linter\n")
      File.touch!(path, {{2035, 1, 1}, {0, 0, 0}})

      assert {:error, msg} = edit(path, "beta", "BETA", ctx)
      assert msg =~ "changed on disk"
      assert msg =~ "Re-read"
    end

    test "re-reading after an external change clears the stale flag", %{ctx: ctx, path: path} do
      File.write!(path, "alpha\nbeta\n")
      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      File.write!(path, "alpha\nbeta\nEXTRA\n")
      File.touch!(path, {{2035, 1, 1}, {0, 0, 0}})

      assert {:error, _} = edit(path, "beta", "BETA", ctx)

      # Re-read → tracker refreshed → edit now allowed.
      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)
      assert :ok == edit(path, "beta", "BETA", ctx) |> elem(0)
    end
  end

  describe "new-file write is exempt" do
    test "file_write to a non-existent path succeeds without a prior read", %{
      ctx: ctx,
      path: path
    } do
      refute File.exists?(path)

      assert {:ok, _} =
               FileWrite.execute(%{"path" => path, "content" => "brand new\n"}, ctx)
               |> normalize_ok()

      assert File.read!(path) == "brand new\n"
    end
  end

  describe "successful write refreshes the tracker" do
    test "back-to-back edits in the same turn pass without re-reading", %{ctx: ctx, path: path} do
      File.write!(path, "one\ntwo\nthree\n")
      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      # First edit changes the file's mtime; the handler must refresh the entry.
      assert :ok == edit(path, "two", "TWO", ctx) |> elem(0)
      # Second edit — no intervening file_read — must still pass (not stale).
      assert :ok == edit(path, "three", "THREE", ctx) |> elem(0)
      assert File.read!(path) == "one\nTWO\nTHREE\n"
    end

    test "a fresh file_write counts as read for a subsequent edit", %{ctx: ctx, path: path} do
      assert {:ok, _} =
               FileWrite.execute(%{"path" => path, "content" => "created\ncontent\n"}, ctx)
               |> normalize_ok()

      # No explicit file_read — the write recorded the state — so an edit passes.
      assert :ok == edit(path, "content", "CONTENT", ctx) |> elem(0)
      assert File.read!(path) == "created\nCONTENT\n"
    end
  end

  describe "multi_file_edit enforcement" do
    test "an unread target fails the whole atomic batch (no files modified)", %{
      ctx: ctx,
      path: path
    } do
      read_path =
        Path.join(System.tmp_dir!(), "osa_fs_mfe_read_#{System.unique_integer([:positive])}.txt")

      on_exit(fn -> File.rm(read_path) end)

      File.write!(read_path, "keep\nreplaceme\n")
      File.write!(path, "other\ntarget\n")
      assert {:ok, _} = FileRead.execute(%{"path" => read_path}, ctx)
      # `path` is never read this session.

      assert {:error, msg} =
               MultiFileEdit.execute(
                 %{
                   "edits" => [
                     %{
                       "path" => read_path,
                       "old_string" => "replaceme",
                       "new_string" => "REPLACED"
                     },
                     %{"path" => path, "old_string" => "target", "new_string" => "TARGET"}
                   ]
                 },
                 ctx
               )

      assert msg =~ "must read"
      # Atomic: neither file was modified.
      assert File.read!(read_path) == "keep\nreplaceme\n"
      assert File.read!(path) == "other\ntarget\n"
    end

    test "all-read targets apply atomically", %{ctx: ctx, path: path} do
      p2 = Path.join(System.tmp_dir!(), "osa_fs_mfe2_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(p2) end)

      File.write!(path, "aaa\nfoo\n")
      File.write!(p2, "bbb\nbar\n")
      assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)
      assert {:ok, _} = FileRead.execute(%{"path" => p2}, ctx)

      assert {:ok, _summary, %{count: 2}} =
               MultiFileEdit.execute(
                 %{
                   "edits" => [
                     %{"path" => path, "old_string" => "foo", "new_string" => "FOO"},
                     %{"path" => p2, "old_string" => "bar", "new_string" => "BAR"}
                   ]
                 },
                 ctx
               )

      assert File.read!(path) == "aaa\nFOO\n"
      assert File.read!(p2) == "bbb\nBAR\n"
    end
  end

  describe "unicode-normalised filenames (#212)" do
    # A filename's accented character can be stored composed (NFC, é = U+00E9)
    # or decomposed (NFD, e + U+0301) and both render identically. Linux
    # filesystems preserve the exact bytes handed to them, so file_read's
    # Unicode rescue records the read under the on-disk NFD name while the model
    # later edits under the NFC name it typed. The ledger must key both to one
    # canonical form, and — the part #212 got wrong — must stat the real
    # on-disk path, not the normalised key, or the read is never recorded.
    #
    # macOS (APFS) collapses NFC/NFD at the FS layer, so these pass there with
    # or without the fix; on Linux they fail without it (record_read stats the
    # NFC path, which does not exist, and drops the read).
    setup do
      base = "cafe" <> <<0x65, 0xCC, 0x81>>
      nfd = :unicode.characters_to_nfd_binary(base)
      nfc = :unicode.characters_to_nfc_binary(base)
      # Guard the fixture itself: the two forms must actually differ, or the
      # test proves nothing.
      assert nfd != nfc

      dir = Path.join(System.tmp_dir!(), "osa_nfd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      nfd_path = Path.join(dir, nfd <> ".txt")
      nfc_path = Path.join(dir, nfc <> ".txt")
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, nfd_path: nfd_path, nfc_path: nfc_path}
    end

    test "a read recorded under the NFD name is found under the NFC name", ctx do
      %{sid: sid, nfd_path: nfd_path, nfc_path: nfc_path} = ctx
      File.write!(nfd_path, "alpha\nbeta\n")

      # file_read rescues the caller's path to the on-disk (NFD) form and
      # records the read against it.
      FileState.record_read(sid, nfd_path)

      # The subsequent edit names the file in its NFC form; enforcement must
      # recognise it as already read.
      assert FileState.read?(sid, nfc_path)
      assert :ok == FileState.check_read(sid, nfc_path)
    end

    test "the rescued read is actually recorded (stat hits the real path, not the key)", ctx do
      %{sid: sid, nfd_path: nfd_path} = ctx
      File.write!(nfd_path, "alpha\nbeta\n")

      # The read is recorded against the real on-disk (NFD) path. Without the
      # fix, record_read stats the NFC-normalised key instead — a path that does
      # not exist on Linux — so nothing is inserted and even the same-form
      # lookup misses.
      FileState.record_read(sid, nfd_path)

      assert FileState.read?(sid, nfd_path)
      assert :ok == FileState.check_read(sid, nfd_path)
    end
  end

  describe "legacy/exempt sessions" do
    test "the \"test\" sentinel session is not enforced (flat-shim compat)", %{path: path} do
      File.write!(path, "alpha\nbeta\n")
      exempt_ctx = UseContext.empty()
      assert exempt_ctx.session_id == "test"

      # No prior read, yet the edit is allowed because the session is exempt.
      assert :ok == edit(path, "beta", "BETA", exempt_ctx) |> elem(0)
      assert File.read!(path) == "alpha\nBETA\n"
    end
  end

  # file_write returns {:ok, result} or {:ok, result, meta}; collapse to a
  # 2-tuple-friendly match for assertions that only care about success.
  defp normalize_ok({:ok, _} = ok), do: ok
  defp normalize_ok({:ok, r, _meta}), do: {:ok, r}
  defp normalize_ok(other), do: other
end
