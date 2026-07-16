defmodule OptimalSystemAgent.Tools.ToolHandlerHardeningTest do
  @moduledoc """
  Regression tests for defensive hardening of tool handlers:

    * file_read: whole-file size cap (finding 24) and binary/non-UTF-8 rejection
      (finding 25) so a huge/binary file can't OOM the node or break downstream
      JSON serialization.
    * file_edit: clean error when the target file cannot be written (finding 26).
    * multi_file_edit: ambiguity error when old_string is not unique (finding 27),
      mirroring single-file file_edit.
    * shell_execute: a malformed OSA_SHELL_TIMEOUT_MS falls back to the default
      instead of raising an opaque argument error on every call (finding 28).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileEdit
  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_tool_hard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "file_read whole-file guards" do
    test "rejects a file larger than the read cap (finding 24)", %{tmp: tmp} do
      path = Path.join(tmp, "huge.txt")
      # One byte over the 20 MB cap.
      File.write!(path, :binary.copy("a", 20 * 1024 * 1024 + 1))

      assert {:error, msg} = FileRead.Handler.execute(%{"path" => path}, nil)
      assert msg =~ "too large"
      assert msg =~ "offset"
    end

    test "rejects a non-UTF-8 binary file (finding 25)", %{tmp: tmp} do
      path = Path.join(tmp, "blob.bin")
      # Invalid UTF-8 byte sequence.
      File.write!(path, <<0xFF, 0xFE, 0x00, 0x80>>)

      assert {:error, msg} = FileRead.Handler.execute(%{"path" => path}, nil)
      assert msg =~ "binary" or msg =~ "non-UTF-8"
    end

    test "still reads a normal small text file", %{tmp: tmp} do
      path = Path.join(tmp, "ok.txt")
      File.write!(path, "hello world")
      assert {:ok, "hello world"} = FileRead.Handler.execute(%{"path" => path}, nil)
    end
  end

  describe "file_edit write failure (finding 26)" do
    @tag :unix
    test "returns a clean Cannot write error on a read-only file", %{tmp: tmp} do
      path = Path.join(tmp, "ro.txt")
      File.write!(path, "alpha beta")
      File.chmod!(path, 0o444)

      result =
        FileEdit.Handler.execute(
          %{"path" => path, "old_string" => "alpha", "new_string" => "gamma"},
          nil
        )

      # Root can write through 0444, so accept either the clean error (normal
      # user) or a successful edit (running as root) — but never a raise.
      case result do
        {:error, msg} -> assert msg =~ "Cannot write"
        {:ok, _} -> :ok
        {:ok, _, _} -> :ok
      end
    end
  end

  describe "multi_file_edit ambiguity guard (finding 27)" do
    test "errors when old_string occurs multiple times", %{tmp: tmp} do
      path = Path.join(tmp, "dup.txt")
      File.write!(path, "foo\nfoo\n")

      assert {:error, msg} =
               MultiFileEdit.Handler.execute(
                 %{"edits" => [%{"path" => path, "old_string" => "foo", "new_string" => "bar"}]},
                 nil
               )

      assert msg =~ "multiple times"
      # No files modified on validation failure.
      assert File.read!(path) == "foo\nfoo\n"
    end

    test "still applies a unique edit", %{tmp: tmp} do
      path = Path.join(tmp, "uniq.txt")
      File.write!(path, "foo\nbar\n")

      assert {:ok, _, _} =
               MultiFileEdit.Handler.execute(
                 %{"edits" => [%{"path" => path, "old_string" => "bar", "new_string" => "baz"}]},
                 nil
               )

      assert File.read!(path) == "foo\nbaz\n"
    end
  end

  describe "shell_execute timeout parsing (finding 28)" do
    # Test the pure parser directly — no process-global System.put_env, which
    # flaked under parallel runs (a concurrent shell_execute could observe the
    # mutated env before on_exit restored it).
    test "malformed OSA_SHELL_TIMEOUT_MS falls back to the default instead of raising" do
      default = OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants.default_timeout_ms()

      # Pre-fix, "30s" hit String.to_integer/1 and raised ArgumentError before the
      # run_command rescue, breaking EVERY shell call until the env var was fixed.
      assert ShellExecute.Handler.parse_timeout_ms("30s") == default
      assert ShellExecute.Handler.parse_timeout_ms("") == default
      assert ShellExecute.Handler.parse_timeout_ms("  ") == default
      assert ShellExecute.Handler.parse_timeout_ms("-5") == default
      assert ShellExecute.Handler.parse_timeout_ms("0") == default
      assert ShellExecute.Handler.parse_timeout_ms(nil) == default
      # Valid values parse through unchanged.
      assert ShellExecute.Handler.parse_timeout_ms("5000") == 5000
      assert ShellExecute.Handler.parse_timeout_ms(" 45000 ") == 45000
    end
  end
end
