defmodule OptimalSystemAgent.Agent.Loop.CheckpointRewindTest do
  @moduledoc """
  Tests for the /rewind checkpoint history added to Loop.Checkpoint.

  Covers create/list/get/restore/prune of rewind checkpoints, which snapshot
  conversation + code state before each user prompt.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_rewind_test_#{System.unique_integer([:positive])}")
    crash = Path.join(tmp, "crash")
    rewind = Path.join(tmp, "rewind")

    prev_rewind = Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir)
    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)

    Application.put_env(:optimal_system_agent, :rewind_checkpoint_dir, rewind)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash)

    on_exit(fn ->
      restore_env(:rewind_checkpoint_dir, prev_rewind)
      restore_env(:checkpoint_dir, prev_crash)
      File.rm_rf(tmp)
    end)

    {:ok, session: "sess_#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp state(session, messages, opts \\ []) do
    %{
      session_id: session,
      messages: messages,
      iteration: Keyword.get(opts, :iteration, 0),
      plan_mode: Keyword.get(opts, :plan_mode, false),
      turn_count: Keyword.get(opts, :turn_count, 0)
    }
  end

  describe "create_rewind_checkpoint/2" do
    test "creates a checkpoint and returns its id", %{session: session} do
      msgs = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]

      assert {:ok, id} =
               Checkpoint.create_rewind_checkpoint(state(session, msgs),
                 fs_head: nil,
                 label: "next prompt"
               )

      assert is_binary(id)

      path = Path.join(Checkpoint.rewind_session_dir(session), id <> ".json")
      assert File.exists?(path)
    end

    test "truncates and normalises the label", %{session: session} do
      long = String.duplicate("x", 500)

      assert {:ok, id} =
               Checkpoint.create_rewind_checkpoint(state(session, []),
                 fs_head: nil,
                 label: "  a\n\nb  " <> long
               )

      assert {:ok, entry} = Checkpoint.get_rewind_checkpoint(session, id)
      assert String.length(entry.label) <= 120
      refute entry.label =~ "\n"
    end

    test "non-binary label falls back to 'checkpoint'", %{session: session} do
      assert {:ok, id} =
               Checkpoint.create_rewind_checkpoint(state(session, []),
                 fs_head: nil,
                 label: [%{type: "image"}]
               )

      assert {:ok, entry} = Checkpoint.get_rewind_checkpoint(session, id)
      assert entry.label == "checkpoint"
    end
  end

  describe "list_rewind_checkpoints/2" do
    test "returns metadata newest-first without message payloads", %{session: session} do
      {:ok, _} =
        Checkpoint.create_rewind_checkpoint(state(session, [%{role: "user", content: "1"}]),
          fs_head: nil,
          label: "one"
        )

      Process.sleep(2)

      {:ok, _} =
        Checkpoint.create_rewind_checkpoint(
          state(session, [%{role: "user", content: "1"}, %{role: "user", content: "2"}]),
          fs_head: nil,
          label: "two"
        )

      list = Checkpoint.list_rewind_checkpoints(session)
      assert length(list) == 2
      [first, second] = list
      assert first.created_ms >= second.created_ms
      assert first.label == "two"
      assert first.message_count == 2
      # metadata entries do not carry the raw messages
      refute Map.has_key?(first, :messages)
    end

    test "empty for unknown session" do
      assert Checkpoint.list_rewind_checkpoints("nope_#{System.unique_integer([:positive])}") ==
               []
    end

    test "respects the limit argument", %{session: session} do
      for i <- 1..5 do
        {:ok, _} =
          Checkpoint.create_rewind_checkpoint(state(session, []), fs_head: nil, label: "l#{i}")

        Process.sleep(2)
      end

      assert length(Checkpoint.list_rewind_checkpoints(session, 3)) == 3
    end
  end

  describe "restore_rewind/3 conversation scope" do
    test "returns messages and rewrites the crash-recovery checkpoint", %{session: session} do
      msgs = [%{role: "user", content: "remember this"}, %{role: "assistant", content: "ok"}]

      {:ok, id} =
        Checkpoint.create_rewind_checkpoint(state(session, msgs, iteration: 4, turn_count: 2),
          fs_head: nil,
          label: "p"
        )

      assert {:ok, result} = Checkpoint.restore_rewind(session, id, :conversation)
      assert result.scope == :conversation
      assert result.code == :skipped
      assert length(result.messages) == 2
      assert result.iteration == 4
      assert result.turn_count == 2

      # The crash-recovery checkpoint now reflects the restored conversation.
      restored = Checkpoint.restore_checkpoint(session)
      assert length(restored.messages) == 2
      assert restored.iteration == 4
    end
  end

  describe "restore_rewind/3 code scope" do
    test "reports unavailable when no code snapshot was captured", %{session: session} do
      {:ok, id} =
        Checkpoint.create_rewind_checkpoint(state(session, []), fs_head: nil, label: "p")

      assert {:ok, result} = Checkpoint.restore_rewind(session, id, :code)
      assert result.conversation == :skipped
      assert result.messages == nil
      assert %{status: "unavailable"} = result.code
    end
  end

  describe "restore_rewind/3 errors" do
    test "not_found for unknown checkpoint", %{session: session} do
      assert {:error, :not_found} = Checkpoint.restore_rewind(session, "does_not_exist", :both)
    end

    test "invalid scope is rejected", %{session: session} do
      {:ok, id} =
        Checkpoint.create_rewind_checkpoint(state(session, []), fs_head: nil, label: "p")

      assert {:error, :invalid_scope} = Checkpoint.restore_rewind(session, id, :bogus)
    end
  end

  describe "prune_rewind/2" do
    test "keeps only the newest N checkpoints", %{session: session} do
      for i <- 1..6 do
        {:ok, _} =
          Checkpoint.create_rewind_checkpoint(state(session, []), fs_head: nil, label: "l#{i}")

        Process.sleep(2)
      end

      :ok = Checkpoint.prune_rewind(session, 3)
      assert length(Checkpoint.list_rewind_checkpoints(session)) == 3
    end
  end

  describe "clear_rewind_checkpoints/1" do
    test "removes all checkpoints for the session", %{session: session} do
      {:ok, _} = Checkpoint.create_rewind_checkpoint(state(session, []), fs_head: nil, label: "p")
      assert length(Checkpoint.list_rewind_checkpoints(session)) == 1

      :ok = Checkpoint.clear_rewind_checkpoints(session)
      assert Checkpoint.list_rewind_checkpoints(session) == []
    end
  end
end
