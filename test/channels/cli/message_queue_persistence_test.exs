defmodule OptimalSystemAgent.Channels.CLI.MessageQueuePersistenceTest do
  @moduledoc """
  Task #32 — durable per-session message queue.

  Queued-but-unsent messages (accepted while the agent is busy) are mirrored to
  the session store so they survive a backend restart, then restored when the
  MessageQueue for that session is (re)started.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Channels.CLI.MessageQueue

  # Runtime-resolved (see FrozenHomeRuntimeTest): a compile-time `~/.osa`
  # here writes into the OPERATOR's real home instead of the suite's
  # isolated per-run config dir.
  defp sessions_dir, do: Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "sessions")

  defp session_file(id) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    Path.join(sessions_dir(), "#{safe}.json")
  end

  setup do
    id = "osa_mq_persist_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm(session_file(id)) end)
    {:ok, id: id}
  end

  describe "SessionPersistence queue mirror" do
    test "save_queue/load_queue round-trips message texts", %{id: id} do
      assert :ok = SessionPersistence.save_queue(id, ["first", "second", "third"])
      assert ["first", "second", "third"] == SessionPersistence.load_queue(id)
    end

    test "load_queue returns [] when nothing was persisted", %{id: id} do
      assert [] == SessionPersistence.load_queue(id)
    end

    test "save_queue with [] clears the mirror", %{id: id} do
      :ok = SessionPersistence.save_queue(id, ["pending"])
      assert ["pending"] == SessionPersistence.load_queue(id)

      :ok = SessionPersistence.save_queue(id, [])
      assert [] == SessionPersistence.load_queue(id)
    end

    test "non-binary entries are dropped, not persisted", %{id: id} do
      :ok = SessionPersistence.save_queue(id, ["ok", 123, %{a: 1}, "also-ok"])
      assert ["ok", "also-ok"] == SessionPersistence.load_queue(id)
    end

    test "queued messages survive a message-only save/3 (auto_save clobber guard)", %{id: id} do
      :ok = SessionPersistence.save_queue(id, ["queued-1", "queued-2"])

      # A later message-only save (what auto_save does) must not drop the queue.
      :ok = SessionPersistence.save(id, [%{role: "user", content: "hello"}])

      assert ["queued-1", "queued-2"] == SessionPersistence.load_queue(id)
      assert {:ok, [%{role: "user"} | _]} = SessionPersistence.load(id)
    end
  end

  describe "MessageQueue restore on init" do
    test "restores persisted queue so has_queued? is true after restart", %{id: id} do
      # Simulate a queue that was persisted before a restart.
      :ok = SessionPersistence.save_queue(id, ["survivor"])

      {:ok, pid} = MessageQueue.start_link(id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert MessageQueue.has_queued?(id)
    end

    test "a fresh session with no persisted queue starts empty", %{id: id} do
      {:ok, pid} = MessageQueue.start_link(id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      refute MessageQueue.has_queued?(id)
    end

    test "submit reports accepted versus queued instead of making the UI guess", %{id: id} do
      {:ok, pid} = MessageQueue.start_link(id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert %{status: :accepted, session_id: ^id} = MessageQueue.submit(id, "first")
      :sys.replace_state(pid, &%{&1 | agent_busy: true})

      assert %{status: :queued, session_id: ^id, position: 1} =
               MessageQueue.submit(id, "second")
    end
  end
end
