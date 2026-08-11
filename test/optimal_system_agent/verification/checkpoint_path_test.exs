defmodule OptimalSystemAgent.Verification.CheckpointPathTest do
  @moduledoc """
  Checkpoint filenames are built from ids that arrive from tool input.

  `Verification.Checkpoint` interpolated `loop_id` straight into
  `Path.join(checkpoint_dir(), "\#{loop_id}.json")`, and `Agent.Loop.Checkpoint`
  did the same with `session_id` on the crash-recovery path — while its own
  rewind path already sanitised. A `..`-bearing id therefore steered a
  `File.write/3` (and a `File.rm/1`) anywhere on disk the daemon could reach.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint, as: LoopCheckpoint
  alias OptimalSystemAgent.Verification.Checkpoint

  @traversal "../../../../tmp/osa-checkpoint-escape"

  describe "Verification.Checkpoint" do
    test "a traversal id cannot escape the checkpoint directory" do
      path = Checkpoint.checkpoint_path(@traversal)

      assert Path.dirname(path) == Checkpoint.checkpoint_dir()
      refute String.contains?(path, "..")
    end

    test "save/2 writes inside the checkpoint directory and nowhere else" do
      escape = Path.expand("~/.osa/osa-checkpoint-escape.json")
      File.rm(escape)

      assert :ok = Checkpoint.save("../osa-checkpoint-escape", %{iteration: 1})

      refute File.exists?(escape), "checkpoint escaped its directory"

      written = Checkpoint.checkpoint_path("../osa-checkpoint-escape")
      assert File.exists?(written)
      File.rm(written)
    end

    test "ordinary ids are unaffected" do
      assert Checkpoint.checkpoint_path("vloop_abc-123") ==
               Path.join(Checkpoint.checkpoint_dir(), "vloop_abc-123.json")
    end
  end

  describe "Agent.Loop.Checkpoint" do
    test "a traversal session id cannot escape the checkpoint directory" do
      path = LoopCheckpoint.checkpoint_path(@traversal)

      assert Path.dirname(path) == LoopCheckpoint.checkpoint_dir()
      refute String.contains?(Path.basename(path), "/")
      refute path =~ ~r|/\.\./|
    end

    test "ordinary ids are unaffected" do
      assert LoopCheckpoint.checkpoint_path("sess_abc-123") ==
               Path.join(LoopCheckpoint.checkpoint_dir(), "sess_abc-123.json")
    end
  end
end
