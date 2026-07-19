defmodule OptimalSystemAgent.Agent.RewindTest do
  @moduledoc """
  Tests for the unified `/rewind` coordinator (`OptimalSystemAgent.Agent.Rewind`):

    * `rewind_to/3` restores files (via the real FSCheckpoint shadow repo)
      AND truncates the conversation to the target checkpoint, in one call,
      while recording an undo point.
    * `unrevert/1` restores both files and messages forward again.
    * `diff_summary/2` reports additions/deletions/files-changed correctly.

  Uses the real `FSCheckpoint.Server` (started under the app's supervision
  tree, backed by `~/.osa/fs_checkpoints`) since its repo path is not
  test-overridable — mirrors how the feature actually runs in production.
  Every test uses a fresh scratch file under a unique tmp dir so runs never
  collide, and `async: false` since the server is a single shared GenServer.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Rewind
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.FSCheckpoint.Server, as: FSCheckpoint

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_rewind_coord_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    file = Path.join(tmp, "scratch.txt")

    prev_rewind = Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir)
    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)

    rewind_dir = Path.join(tmp, "rewind")
    crash_dir = Path.join(tmp, "crash")
    Application.put_env(:optimal_system_agent, :rewind_checkpoint_dir, rewind_dir)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash_dir)

    on_exit(fn ->
      restore_env(:rewind_checkpoint_dir, prev_rewind)
      restore_env(:checkpoint_dir, prev_crash)
      File.rm_rf(tmp)
    end)

    session = "rewind_coord_#{System.unique_integer([:positive])}"
    {:ok, session: session, scratch_file: file}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # Writes `content` to `file`, snapshots it into the FSCheckpoint shadow
  # repo, and returns the resulting HEAD commit hash.
  defp write_and_snapshot(session, file, content) do
    File.write!(file, content)
    FSCheckpoint.snapshot(session, "file_write", [file])
    # snapshot/3 casts; give the GenServer a moment to commit before reading HEAD.
    wait_for_head_change()
  end

  defp wait_for_head_change do
    # GenServer.call is synchronous against the same mailbox as the earlier
    # cast, so by the time `head/0` replies the snapshot cast has already
    # been processed (casts and calls from the same caller are ordered).
    FSCheckpoint.head()
  end

  describe "rewind_to/3" do
    test "restores files and truncates messages to the target checkpoint, recording an undo point",
         %{session: session, scratch_file: file} do
      head1 = write_and_snapshot(session, file, "v1\n")

      msgs1 = [%{role: "user", content: "first"}, %{role: "assistant", content: "ack"}]
      {:ok, target_id} =
        Checkpoint.create_rewind_checkpoint(
          %{session_id: session, messages: msgs1, iteration: 1, plan_mode: false, turn_count: 1},
          fs_head: head1,
          label: "before edit"
        )

      _head2 = write_and_snapshot(session, file, "v1\nv2\nv3\n")

      msgs2 = msgs1 ++ [%{role: "user", content: "second"}, %{role: "assistant", content: "done"}]
      # Represent "current state" the way the crash-recovery checkpoint does
      # (written after every tool cycle) — no live Loop process is required.
      Checkpoint.checkpoint_state(%{
        session_id: session,
        messages: msgs2,
        iteration: 2,
        plan_mode: false,
        turn_count: 2
      })

      assert {:ok, result} = Rewind.rewind_to(session, target_id, :both)

      assert result.id == target_id
      assert result.scope == :both
      assert length(result.messages) == 2
      assert File.read!(file) == "v1\n"

      # Diff reported what this rewind was about to undo (2 lines added).
      assert result.diff.files == 1
      assert result.diff.additions == 2
      assert result.diff.deletions == 0
      assert result.diff.messages.removed == 2

      # An undo point was recorded pointing at a fresh checkpoint id.
      assert is_binary(result.undo_id)
      assert result.undo_id != target_id

      assert {:ok, pointer} = Rewind.last_rewind(session)
      assert pointer.undo_id == result.undo_id
      assert pointer.target_id == target_id
    end
  end

  describe "unrevert/1" do
    test "restores files and messages forward to the pre-rewind state", %{session: session, scratch_file: file} do
      head1 = write_and_snapshot(session, file, "v1\n")

      msgs1 = [%{role: "user", content: "first"}]
      {:ok, target_id} =
        Checkpoint.create_rewind_checkpoint(
          %{session_id: session, messages: msgs1, iteration: 1, plan_mode: false, turn_count: 1},
          fs_head: head1,
          label: "before edit"
        )

      write_and_snapshot(session, file, "v1\nv2\n")
      msgs2 = msgs1 ++ [%{role: "assistant", content: "reply"}, %{role: "user", content: "more"}]

      Checkpoint.checkpoint_state(%{
        session_id: session,
        messages: msgs2,
        iteration: 3,
        plan_mode: false,
        turn_count: 3
      })

      assert {:ok, _rewound} = Rewind.rewind_to(session, target_id, :both)
      assert File.read!(file) == "v1\n"
      assert Checkpoint.restore_checkpoint(session).messages |> length() == 1

      assert {:ok, result} = Rewind.unrevert(session)

      assert File.read!(file) == "v1\nv2\n"
      assert length(result.messages) == 3
      assert Checkpoint.restore_checkpoint(session).messages |> length() == 3

      # Undo point is consumed — a second unrevert has nothing to undo.
      assert {:error, :no_rewind_to_undo} = Rewind.unrevert(session)
      assert {:error, :none} = Rewind.last_rewind(session)
    end
  end

  describe "diff_summary/2" do
    test "reports additions, deletions, and files changed between current and target", %{
      session: session,
      scratch_file: file
    } do
      head1 = write_and_snapshot(session, file, "a\nb\nc\n")

      {:ok, target_id} =
        Checkpoint.create_rewind_checkpoint(
          %{session_id: session, messages: [%{role: "user", content: "x"}], iteration: 0, plan_mode: false, turn_count: 0},
          fs_head: head1,
          label: "baseline"
        )

      write_and_snapshot(session, file, "a\nb\nd\ne\n")

      diff = Rewind.diff_summary(session, target_id)

      assert diff.files == 1
      # "c" removed, "d" and "e" added relative to the target (target -> current).
      assert diff.additions == 2
      assert diff.deletions == 1
      assert diff.paths == [String.trim_leading(file, "/")]
      assert diff.messages.removed == 0
    end

    test "zeroes out file diff when the checkpoint captured no code snapshot", %{session: session} do
      {:ok, target_id} =
        Checkpoint.create_rewind_checkpoint(
          %{session_id: session, messages: [], iteration: 0, plan_mode: false, turn_count: 0},
          fs_head: nil,
          label: "no code"
        )

      diff = Rewind.diff_summary(session, target_id)
      assert diff.files == 0
      assert diff.additions == 0
      assert diff.deletions == 0
    end

    test "returns an empty diff for an unknown checkpoint", %{session: session} do
      diff = Rewind.diff_summary(session, "does_not_exist")
      assert diff.files == 0
      assert diff.messages.removed == 0
    end
  end
end
