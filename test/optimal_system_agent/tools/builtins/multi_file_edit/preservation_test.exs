defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.PreservationTest do
  @moduledoc """
  What `multi_file_edit` must NOT destroy while editing (finding 4).

  Every test here fails against the pre-fix stage-to-temp-then-`File.rename`
  implementation, which swapped the target's inode on every single edit.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler
  alias OptimalSystemAgent.Tools.UseContext

  # "test" is the FileState read-before-edit exempt sentinel, matching the
  # convention in the sibling atomic_test suite. These tests are about what the
  # apply phase preserves, not about read-before-edit.
  defp ctx, do: %UseContext{session_id: "test"}

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_mfe_pres_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp edit(path, old, new), do: %{"path" => path, "old_string" => old, "new_string" => new}

  describe "file metadata survives an edit" do
    test "the execute bit is preserved", %{dir: dir} do
      # Pre-fix: rename replaced the inode with a fresh 0644 file, so editing a
      # script silently made it non-executable.
      script = Path.join(dir, "run.sh")
      File.write!(script, "#!/bin/sh\necho old\n")
      File.chmod!(script, 0o755)

      assert {:ok, _, _} =
               Handler.execute(%{"edits" => [edit(script, "old", "new")]}, ctx())

      assert File.read!(script) == "#!/bin/sh\necho new\n"
      assert %File.Stat{mode: mode} = File.stat!(script)
      assert Bitwise.band(mode, 0o111) != 0, "the execute bit was lost"
    end

    test "the inode is preserved", %{dir: dir} do
      file = Path.join(dir, "a.txt")
      File.write!(file, "alpha\n")
      %File.Stat{inode: before_inode} = File.stat!(file)

      assert {:ok, _, _} = Handler.execute(%{"edits" => [edit(file, "alpha", "beta")]}, ctx())

      assert %File.Stat{inode: ^before_inode} = File.stat!(file)
    end

    test "hard links see the edit", %{dir: dir} do
      # Pre-fix the rename detached the link: the other name kept the OLD
      # content forever, with nothing reported.
      original = Path.join(dir, "original.txt")
      linked = Path.join(dir, "linked.txt")
      File.write!(original, "shared\n")
      :ok = File.ln!(original, linked)

      assert {:ok, _, _} =
               Handler.execute(%{"edits" => [edit(original, "shared", "changed")]}, ctx())

      assert File.read!(original) == "changed\n"
      assert File.read!(linked) == "changed\n", "the hard link was severed by the edit"
    end
  end

  describe "symlinked targets" do
    test "editing through a symlink updates the real file and keeps the link", %{dir: dir} do
      # Pre-fix: renaming over the symlink DELETED it, left a regular file in
      # its place, and never touched the file the link pointed at.
      real = Path.join(dir, "real.txt")
      link = Path.join(dir, "link.txt")
      File.write!(real, "content\n")
      File.ln_s!(real, link)

      assert {:ok, _, _} =
               Handler.execute(%{"edits" => [edit(link, "content", "updated")]}, ctx())

      assert File.read!(real) == "updated\n", "the real file was never updated"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link), "the symlink was destroyed"
    end
  end

  describe "no temp files are left behind" do
    test "a successful batch leaves only the edited files", %{dir: dir} do
      # Pre-fix, staging wrote `<target>.osa-tmp-<monotonic int>` siblings
      # inside the user's own repo. They were removed only on the explicit
      # failure branches, so a crash left them for compilers and git status,
      # and no sweeper existed anywhere.
      a = Path.join(dir, "a.txt")
      b = Path.join(dir, "b.txt")
      File.write!(a, "alpha\n")
      File.write!(b, "beta\n")

      assert {:ok, _, _} =
               Handler.execute(
                 %{"edits" => [edit(a, "alpha", "ALPHA"), edit(b, "beta", "BETA")]},
                 ctx()
               )

      assert Enum.sort(File.ls!(dir)) == ["a.txt", "b.txt"]
      refute Enum.any?(File.ls!(dir), &String.contains?(&1, "osa-tmp"))
    end

    test "a failed batch leaves no temp files either", %{dir: dir} do
      a = Path.join(dir, "a.txt")
      File.write!(a, "alpha\n")

      # Second hunk fails validation, so nothing is applied.
      edits = [edit(a, "alpha", "ALPHA"), edit(Path.join(dir, "missing.txt"), "x", "y")]

      assert {:error, _} = Handler.execute(%{"edits" => edits}, ctx())
      assert File.ls!(dir) == ["a.txt"]
      assert File.read!(a) == "alpha\n"
    end
  end

  describe "permission guard matches its siblings (finding 2)" do
    test "a dotfile outside ~/.osa is refused" do
      # Pre-fix `multi_file_edit` had no dotfile clause at all, so it could
      # write where file_edit and file_write both refused.
      edits = [edit(Path.join(Path.expand("~"), ".zshrc"), "a", "b")]

      assert {:deny, message} = Handler.check_permissions(%{"edits" => edits}, ctx())
      assert message =~ "dotfile"
    end

    test "a git control directory is refused" do
      edits = [edit(Path.join(Path.expand("~"), "projects/x/.git/config"), "a", "b")]

      assert {:deny, _} = Handler.check_permissions(%{"edits" => edits}, ctx())
    end

    test "an intermediate directory symlink cannot escape the allowlist", %{dir: dir} do
      # Pre-fix there was no symlink resolution here whatsoever.
      link = Path.join(dir, "escape")
      File.ln_s!("/etc", link)
      edits = [edit(Path.join(link, "passwd"), "a", "b")]

      assert {:deny, _} = Handler.check_permissions(%{"edits" => edits}, ctx())
    end

    test "an ordinary temp file is still allowed", %{dir: dir} do
      edits = [edit(Path.join(dir, "ok.txt"), "a", "b")]
      assert {:allow, _} = Handler.check_permissions(%{"edits" => edits}, ctx())
    end
  end
end
