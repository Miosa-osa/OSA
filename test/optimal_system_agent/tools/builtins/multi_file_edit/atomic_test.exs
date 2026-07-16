defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.AtomicTest do
  @moduledoc """
  Atomicity guarantees for multi_file_edit (BUG B): a multi-file edit that fails
  partway must leave every target file exactly as it was.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "mfe_atomic_test"}

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
    test "a write failure on one target rolls back the others" do
      dir = tmp_dir()
      # A sub-directory made read-only so temp-file staging fails inside it,
      # even though the target file itself passes validation.
      ro_dir = Path.join(dir, "readonly")
      File.mkdir_p!(ro_dir)

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(ro_dir, "b.txt")
        File.write!(a, "alpha\n")
        File.write!(b, "beta\n")

        # Verify we can actually make staging fail (skip when running as root,
        # which ignores directory permissions).
        File.chmod!(ro_dir, 0o500)
        probe = Path.join(ro_dir, ".probe-#{System.unique_integer([:positive])}")

        if File.write(probe, "x") == :ok do
          File.rm(probe)
          # Root / permissive FS — cannot exercise the failure path here.
          :skipped
        else
          edits = [
            %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
            %{"path" => b, "old_string" => "beta", "new_string" => "BETA"}
          ]

          assert {:error, reason} = Handler.execute(%{"edits" => edits}, ctx())
          assert reason =~ "rolled back"

          # The writable file must be untouched — no partial application.
          assert File.read!(a) == "alpha\n"
          # No stray temp files left behind in the writable dir.
          refute Enum.any?(File.ls!(dir), &String.contains?(&1, ".osa-tmp-"))
        end
      after
        File.chmod(ro_dir, 0o700)
        File.rm_rf!(dir)
      end
    end
  end
end
