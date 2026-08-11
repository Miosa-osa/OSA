defmodule OptimalSystemAgent.FSCheckpoint.IntegrityTest do
  @moduledoc """
  Finding 3: "rollback is theatre".

  Every test here fails against the pre-fix tree.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.FSCheckpoint.{Config, Hook, Server}

  setup do
    repo = Path.join(System.tmp_dir!(), "osa_ckpt_#{System.unique_integer([:positive])}")
    work = Path.join(System.tmp_dir!(), "osa_ckpt_work_#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)

    previous = Application.get_env(:optimal_system_agent, :fs_checkpoint_repo_path)
    Application.put_env(:optimal_system_agent, :fs_checkpoint_repo_path, repo)

    # The supervised Server reads its repo location per call, so pointing the
    # application env at a temp directory is enough to keep this suite out of
    # the operator's real ~/.osa/fs_checkpoints history — no process surgery,
    # and the server every later test depends on stays up.
    unless Process.whereis(Server) do
      {:ok, pid} = Server.start_link([])
      Process.unlink(pid)
    end

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :fs_checkpoint_repo_path, previous)
      else
        Application.delete_env(:optimal_system_agent, :fs_checkpoint_repo_path)
      end

      File.rm_rf!(repo)
      File.rm_rf!(work)
    end)

    {:ok, repo: repo, work: work}
  end

  defp shadow_copy(repo, path), do: Path.join(repo, path)

  defp commit_count(repo) do
    case System.cmd("git", ["rev-list", "--count", "HEAD"], cd: repo, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.to_integer()
      _ -> 0
    end
  end

  describe "the snapshot completes before the write (server.ex:30 / hook.ex:20)" do
    test "snapshot/3 has already committed by the time it returns", %{repo: repo, work: work} do
      file = Path.join(work, "a.ex")
      File.write!(file, "PRE-EDIT\n")

      assert {:ok, %{copied: [^file]}} = Server.snapshot("s1", "file_edit", [file])
      before = commit_count(repo)

      # Pre-fix `snapshot/3` was a GenServer.cast: it returned `:ok` immediately
      # and the copy + `git add`/`commit` subprocesses ran later, so the very
      # next line — and the tool's write — beat the snapshot to the file.
      assert File.read!(shadow_copy(repo, file)) == "PRE-EDIT\n"

      File.write!(file, "POST-EDIT\n")
      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      assert commit_count(repo) == before + 1
    end

    test "back-to-back edits each capture their own PRE-edit content", %{repo: repo, work: work} do
      file = Path.join(work, "b.ex")
      File.write!(file, "v1\n")

      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      assert File.read!(shadow_copy(repo, file)) == "v1\n"

      # The write the hook was protecting.
      File.write!(file, "v2\n")

      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      assert File.read!(shadow_copy(repo, file)) == "v2\n"

      File.write!(file, "v3\n")

      # Restoring the most recent checkpoint must produce v2 — the state before
      # the last write. Under the cast, the queued copy ran after the write and
      # the checkpoint held v3, so the restore was a no-op that reported success.
      {:ok, [latest | _]} = Server.list_checkpoints(5)
      assert {:ok, _} = Server.restore(latest.full_id)
      assert File.read!(file) == "v2\n"
    end
  end

  describe "the commit exit status is not discarded (server.ex:219/:236)" do
    test "a failing commit is reported as an error", %{repo: repo, work: work} do
      file = Path.join(work, "c.ex")
      File.write!(file, "x\n")

      # A first snapshot creates the shadow repo so it can be configured.
      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      File.write!(file, "y\n")

      # Force `git commit` to fail while leaving `git add` working: signing is
      # requested with a program that does not exist.
      assert {_, 0} =
               System.cmd("git", ["config", "commit.gpgsign", "true"],
                 cd: repo,
                 stderr_to_stdout: true
               )

      assert {_, 0} =
               System.cmd("git", ["config", "gpg.program", "/nonexistent/gpg"],
                 cd: repo,
                 stderr_to_stdout: true
               )

      # Pre-fix the status was bound as `{_, _}` and thrown away, then success
      # was logged unconditionally — a failed commit was indistinguishable from
      # a good one.
      assert {:error, reason} = Server.snapshot("s1", "file_edit", [file])
      assert reason =~ "commit failed"
    end
  end

  describe "files that are NOT protected are reported (server.ex:199-204)" do
    test "an oversized file is named in the skip report", %{work: work} do
      big = Path.join(work, "big.bin")
      File.write!(big, :binary.copy("x", Config.max_file_size() + 1))

      small = Path.join(work, "small.ex")
      File.write!(small, "ok\n")

      assert {:ok, %{copied: copied, skipped: skipped}} =
               Server.snapshot("s1", "file_edit", [big, small])

      assert copied == [small]
      assert [{^big, reason}] = skipped
      assert reason =~ "exceeds"
    end
  end

  describe "path framing uses -z (server.ex:311/:363)" do
    test "a non-ASCII filename is restored", %{work: work} do
      # Git quotes this as "caf\303\251.ex" in --name-only output. Splitting on
      # "\n" and prefixing "/" produced a destination that does not exist, so
      # the file was never restored while the caller reported a restore count.
      file = Path.join(work, "café.ex")
      File.write!(file, "original\n")

      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      File.write!(file, "clobbered\n")

      {:ok, [latest | _]} = Server.list_checkpoints(5)
      assert {:ok, message} = Server.restore(latest.full_id)
      assert message =~ "Restored 1 file"
      assert File.read!(file) == "original\n"
    end

    test "restore_to reproduces exact bytes", %{work: work} do
      # restore_to goes through `git show`, whose output used to be captured
      # with stderr_to_stdout: true and written straight into the user's file.
      file = Path.join(work, "crlf.txt")
      content = "line1\r\nline2\r\n"
      File.write!(file, content)

      assert {:ok, _} = Server.snapshot("s1", "file_edit", [file])
      head = Server.head()

      File.write!(file, "destroyed")
      assert {:ok, _} = Server.restore_to(head)
      assert File.read!(file) == content
    end
  end

  describe "shell_execute is actually checkpointed (hook.ex:47-57)" do
    test "rm -rf <file> snapshots the file", %{repo: repo, work: work} do
      # Pre-fix `extract_paths("shell_execute", _)` returned [] from BOTH
      # branches of its if, so destructive shell ran with zero coverage while
      # `Config.shell_destructive_patterns/0` advertised protection.
      file = Path.join(work, "doomed.ex")
      File.write!(file, "important\n")

      assert {:ok, _} =
               Hook.pre_tool_use(%{
                 tool_name: "shell_execute",
                 arguments: %{"command" => "rm -rf #{file}"},
                 session_id: "s1"
               })

      assert File.read!(shadow_copy(repo, file)) == "important\n"
    end

    test "sed -i <file> snapshots the file", %{repo: repo, work: work} do
      file = Path.join(work, "patched.ex")
      File.write!(file, "before\n")

      assert {:ok, _} =
               Hook.pre_tool_use(%{
                 tool_name: "shell_execute",
                 arguments: %{"command" => "sed -i s/before/after/ #{file}"},
                 session_id: "s1"
               })

      assert File.read!(shadow_copy(repo, file)) == "before\n"
    end

    test "a non-destructive command snapshots nothing", %{repo: repo, work: work} do
      file = Path.join(work, "safe.ex")
      File.write!(file, "x\n")

      assert {:ok, _} =
               Hook.pre_tool_use(%{
                 tool_name: "shell_execute",
                 arguments: %{"command" => "cat #{file}"},
                 session_id: "s1"
               })

      refute File.exists?(shadow_copy(repo, file))
    end

    test "a word merely containing a pattern is not destructive", %{repo: repo, work: work} do
      # `String.contains?(command, "rm")` matched "confirm".
      file = Path.join(work, "conf.ex")
      File.write!(file, "x\n")

      assert {:ok, _} =
               Hook.pre_tool_use(%{
                 tool_name: "shell_execute",
                 arguments: %{"command" => "./confirm #{file}"},
                 session_id: "s1"
               })

      refute File.exists?(shadow_copy(repo, file))
    end
  end

  describe "notebook_edit is checkpointed (hook.ex:31/:38)" do
    test "a notebook mutation is snapshotted", %{repo: repo, work: work} do
      nb = Path.join(work, "nb.ipynb")
      File.write!(nb, ~s({"cells":[]}))

      assert {:ok, _} =
               Hook.pre_tool_use(%{
                 tool_name: "notebook_edit",
                 arguments: %{"path" => nb, "action" => "delete_cell", "index" => 0},
                 session_id: "s1"
               })

      # Pre-fix the hook matched only file_write/file_edit/multi_file_edit, so
      # notebook edits were unrecoverable through /rollback.
      assert File.read!(shadow_copy(repo, nb)) == ~s({"cells":[]})
    end
  end
end
