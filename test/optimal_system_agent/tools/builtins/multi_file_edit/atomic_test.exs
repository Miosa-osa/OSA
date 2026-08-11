defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.AtomicTest do
  @moduledoc """
  Atomicity guarantees for multi_file_edit (BUG B): a multi-file edit that fails
  partway must leave every target file exactly as it was.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler
  alias OptimalSystemAgent.Tools.UseContext

  # "test" = FileState read-before-edit exempt sentinel (see multi_file_edit_test);
  # this suite tests apply-phase atomicity/rollback, not read-before-edit.
  defp ctx, do: %UseContext{session_id: "test"}

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "osa_mfe_atomic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  describe "happy path" do
    test "applies all edits when every file is valid" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "alpha\n")
        File.write!(b, "beta\n")

        edits = [
          %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
          %{"path" => b, "old_string" => "beta", "new_string" => "BETA"}
        ]

        assert {:ok, summary, %{count: 2}} = Handler.execute(%{"edits" => edits}, ctx())
        assert summary =~ "Edited 2 files"
        assert File.read!(a) == "ALPHA\n"
        assert File.read!(b) == "BETA\n"
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "validation is all-or-nothing" do
    test "one bad edit leaves every file untouched" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "alpha\n")
        File.write!(b, "beta\n")

        edits = [
          %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
          # old_string not present -> validation failure before any write.
          %{"path" => b, "old_string" => "NOPE", "new_string" => "BETA"}
        ]

        assert {:error, reason} = Handler.execute(%{"edits" => edits}, ctx())
        assert reason =~ "no files were modified"
        # First file must be unchanged despite being valid.
        assert File.read!(a) == "alpha\n"
        assert File.read!(b) == "beta\n"
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "apply-phase atomicity (BUG B)" do
    @tag :tmp
    test "an unwritable target aborts the batch with no file modified" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "alpha\n")
        File.write!(b, "beta\n")

        # The unwritable target is now the FILE, not its directory. The apply
        # phase writes each file in place instead of staging a sibling temp and
        # renaming it (which swapped the inode and destroyed mode, hard links
        # and symlinks — see preservation_test), so a read-only *directory*
        # holding a writable file no longer blocks the edit at all: POSIX
        # directory permissions govern creating and removing entries, not
        # modifying an existing file. Making the file itself read-only is what
        # exercises the failure path now.
        File.chmod!(b, 0o444)

        # Skip when running as root, which ignores file permissions.
        if File.write(b, "probe") == :ok do
          File.write!(b, "beta\n")
          :skipped
        else
          edits = [
            %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
            %{"path" => b, "old_string" => "beta", "new_string" => "BETA"}
          ]

          assert {:error, reason} = Handler.execute(%{"edits" => edits}, ctx())

          # The precheck refuses before ANY file is written, which is a stronger
          # guarantee than rolling back afterwards — and the message says only
          # what is actually true.
          assert reason =~ "no files were modified"

          assert File.read!(a) == "alpha\n"
          assert File.read!(b) == "beta\n"
          refute Enum.any?(File.ls!(dir), &String.contains?(&1, ".osa-tmp-"))
        end
      after
        File.chmod(Path.join(dir, "b.txt"), 0o600)
        File.rm_rf!(dir)
      end
    end
  end
end
