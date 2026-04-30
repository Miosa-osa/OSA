defmodule OptimalSystemAgent.Agent.SessionRecoveryTest do
  @moduledoc """
  Tests for DynamicSupervisor-based session management and
  checkpoint/restore crash recovery in Agent.Loop.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  @checkpoint_dir Path.expand("~/.osa/checkpoints")

  # ---------------------------------------------------------------------------
  # Setup — ensure SessionRegistry and SessionSupervisor are running
  # ---------------------------------------------------------------------------

  setup do
    # SessionRegistry
    case Process.whereis(OptimalSystemAgent.SessionRegistry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry})

      _pid ->
        :ok
    end

    # SessionSupervisor (DynamicSupervisor)
    case Process.whereis(OptimalSystemAgent.SessionSupervisor) do
      nil ->
        start_supervised!(
          {DynamicSupervisor, name: OptimalSystemAgent.SessionSupervisor, strategy: :one_for_one}
        )

      _pid ->
        :ok
    end

    # Ensure cancel flags ETS table exists
    try do
      :ets.new(:osa_cancel_flags, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_session_id do
    "recovery-test-#{:erlang.unique_integer([:positive])}"
  end

  defp checkpoint_path(session_id) do
    Path.join(@checkpoint_dir, "#{session_id}.json")
  end

  # ---------------------------------------------------------------------------
  # Test: Loop starts under DynamicSupervisor
  # ---------------------------------------------------------------------------

  describe "DynamicSupervisor integration" do
    test "Loop starts under SessionSupervisor" do
      session_id = unique_session_id()

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :test}
        )

      assert Process.alive?(pid)

      # Verify it's registered in SessionRegistry
      assert [{^pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)

      # Verify it's a child of the DynamicSupervisor
      children = DynamicSupervisor.which_children(OptimalSystemAgent.SessionSupervisor)
      pids = Enum.map(children, fn {_, pid, _, _} -> pid end)
      assert pid in pids

      # Clean up
      GenServer.stop(pid, :normal)
    end

    test "child_spec uses transient restart strategy" do
      session_id = unique_session_id()
      spec = Loop.child_spec(session_id: session_id, channel: :test)

      assert spec.restart == :transient
      assert spec.id == {Loop, session_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Test: Checkpoint is written after a turn
  # ---------------------------------------------------------------------------

  describe "checkpoint persistence" do
    test "checkpoint_state writes a JSON file for the session" do
      session_id = unique_session_id()

      state = %Loop{
        session_id: session_id,
        channel: :test,
        messages: [
          %{role: "user", content: "hello"},
          %{role: "assistant", content: "hi there"}
        ],
        iteration: 3,
        plan_mode: false,
        turn_count: 2
      }

      Loop.checkpoint_state(state)

      path = checkpoint_path(session_id)
      assert File.exists?(path)

      {:ok, content} = File.read(path)
      {:ok, data} = Jason.decode(content)

      assert data["session_id"] == session_id
      assert data["iteration"] == 3
      assert data["turn_count"] == 2
      assert data["plan_mode"] == false
      assert length(data["messages"]) == 2
      assert data["checkpointed_at"] != nil

      # Clean up
      File.rm(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Test: Restore from checkpoint
  # ---------------------------------------------------------------------------

  describe "checkpoint restore" do
    test "new Loop with same session_id restores from checkpoint" do
      session_id = unique_session_id()

      messages = [
        %{role: "user", content: "build feature X"},
        %{role: "assistant", content: "I'll start by reading..."}
      ]

      # Write a checkpoint manually
      File.mkdir_p!(@checkpoint_dir)

      checkpoint_data = %{
        session_id: session_id,
        messages: messages,
        iteration: 5,
        plan_mode: true,
        turn_count: 3,
        checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(checkpoint_path(session_id), Jason.encode!(checkpoint_data))

      # Start a new Loop — it should restore from the checkpoint
      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :test}
        )

      assert Process.alive?(pid)

      # The checkpoint file should still exist (only cleared on normal exit)
      assert File.exists?(checkpoint_path(session_id))

      # Clean up — normal stop clears the checkpoint
      GenServer.stop(pid, :normal)
      # Give terminate callback time to run
      Process.sleep(50)
      refute File.exists?(checkpoint_path(session_id))
    end

    test "restore_checkpoint returns empty map when no checkpoint exists" do
      session_id = unique_session_id()
      assert Loop.restore_checkpoint(session_id) == %{}
    end

    test "restore_checkpoint returns state from existing checkpoint" do
      session_id = unique_session_id()
      File.mkdir_p!(@checkpoint_dir)

      checkpoint_data = %{
        session_id: session_id,
        messages: [%{role: "user", content: "test msg"}],
        iteration: 7,
        plan_mode: false,
        turn_count: 4,
        checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(checkpoint_path(session_id), Jason.encode!(checkpoint_data))

      restored = Loop.restore_checkpoint(session_id)

      assert restored.iteration == 7
      assert restored.plan_mode == false
      assert restored.turn_count == 4
      assert length(restored.messages) == 1
      assert hd(restored.messages)[:role] == "user" or hd(restored.messages).role == "user"

      # Clean up
      File.rm(checkpoint_path(session_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Test: Normal exit does not trigger restart
  # ---------------------------------------------------------------------------

  describe "normal exit behavior" do
    test "normal stop does not trigger supervisor restart" do
      session_id = unique_session_id()

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :test}
        )

      assert Process.alive?(pid)
      ref = Process.monitor(pid)

      GenServer.stop(pid, :normal)

      # Wait for the process to exit
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # Should NOT be restarted (transient restart = no restart on :normal)
      Process.sleep(100)
      assert Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) == []
    end

    test "normal exit clears checkpoint" do
      session_id = unique_session_id()

      # Write a checkpoint
      File.mkdir_p!(@checkpoint_dir)

      checkpoint_data = %{
        session_id: session_id,
        messages: [%{role: "user", content: "test"}],
        iteration: 1,
        plan_mode: false,
        turn_count: 1,
        checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(checkpoint_path(session_id), Jason.encode!(checkpoint_data))
      assert File.exists?(checkpoint_path(session_id))

      # Start and stop normally
      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :test}
        )

      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # Checkpoint should be cleared
      Process.sleep(50)
      refute File.exists?(checkpoint_path(session_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Test: clear_checkpoint
  # ---------------------------------------------------------------------------

  describe "clear_checkpoint" do
    test "removes checkpoint file" do
      session_id = unique_session_id()
      File.mkdir_p!(@checkpoint_dir)
      File.write!(checkpoint_path(session_id), "{}")

      assert File.exists?(checkpoint_path(session_id))
      Loop.clear_checkpoint(session_id)
      refute File.exists?(checkpoint_path(session_id))
    end

    test "returns :ok even if no checkpoint exists" do
      session_id = unique_session_id()
      assert Loop.clear_checkpoint(session_id) == :ok
    end
  end
end
