defmodule OptimalSystemAgent.Agent.SessionPersistenceBusyLoopTest do
  @moduledoc """
  Durability regression: a session save must never be SILENTLY dropped because
  the Loop is busy.

  The old `auto_save/1` ran in the `:post_response` hook process and scraped the
  loop with `:sys.get_state(pid)` (5s default timeout), wrapped in a blanket
  `rescue _ -> :ok`. A slow or mid-turn loop — exactly what a long session
  produces — made that call fail and the ENTIRE save (transcript + spend) was
  discarded with no log and no retry, while the turn still reported success.

  The fix: `auto_save/1` casts `{:persist_session, id}` at the loop, which a busy
  loop QUEUES instead of dropping, and the loop persists its OWN state via
  `SessionPersistence.save_from_state/2`. A save that genuinely cannot complete
  logs at warning with the session id.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.SessionPersistence

  @dir Path.expand("~/.osa/sessions")

  # Stand-in for Agent.Loop: blocks in handle_call exactly like a mid-turn loop
  # and services {:persist_session, id} the same way Loop does.
  defmodule BusyLoop do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, Map.new(opts[:state] || %{})}

    @impl true
    def handle_call({:block, ms}, _from, state) do
      Process.sleep(ms)
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:persist_session, id}, state) do
      SessionPersistence.save_from_state(id, state)
      {:noreply, state}
    end
  end

  defp safe(id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
  defp session_file(id), do: Path.join(@dir, "#{safe(id)}.json")
  defp updates_file(id), do: Path.join(@dir, "#{safe(id)}.updates.jsonl")
  defp spend_file(id), do: Path.join(@dir, "#{safe(id)}.spend.json")

  setup do
    id = "osa_busy_loop_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each(
        [
          session_file(id),
          updates_file(id),
          updates_file(id) <> ".lock",
          updates_file(id) <> ".corrupt",
          spend_file(id)
        ],
        &File.rm/1
      )
    end)

    {:ok, id: id}
  end

  describe "auto_save/1 against a BUSY loop" do
    test "is queued and eventually persisted, not dropped", %{id: id} do
      messages = [
        %{role: "user", content: "long session turn"},
        %{role: "assistant", content: "work that must survive"}
      ]

      {:ok, pid} =
        BusyLoop.start_link(
          name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, id}},
          state: %{messages: messages, working_dir: File.cwd!(), session_cost_usd: 2.5}
        )

      # Occupy the loop, mimicking a mid-turn GenServer.call.
      blocker = Task.async(fn -> GenServer.call(pid, {:block, 700}, 10_000) end)
      # Make sure the blocking call is actually in progress.
      Process.sleep(50)

      # The old shape's failure mode: a cross-process :sys read of a busy loop
      # EXITS. This is precisely what used to make the save vanish.
      assert catch_exit(:sys.get_state(pid, 100))

      # New shape: enqueueing the save never blocks and never reports success
      # it cannot deliver.
      assert :ok = SessionPersistence.auto_save(id)

      # Still blocked → nothing written yet, but the save is NOT lost.
      refute File.exists?(session_file(id))

      Task.await(blocker, 10_000)

      # Once the loop drains its mailbox the queued save runs.
      assert eventually(fn -> File.exists?(session_file(id)) end)
      assert {:ok, restored} = SessionPersistence.load(id)
      assert length(restored) == 2
      assert Enum.any?(restored, &(&1[:content] == "work that must survive"))

      # Spend is persisted at the same turn boundary (audit gap C2).
      assert SessionPersistence.load_spend(id).cost_usd == 2.5

      GenServer.stop(pid)
    end

    test "returns :ok (no-op) when no loop is registered for the session", %{id: id} do
      assert :ok = SessionPersistence.auto_save(id)
      refute File.exists?(session_file(id))
    end
  end

  describe "Agent.Loop services the save from its OWN state" do
    test "handle_cast({:persist_session, id}) writes transcript and spend", %{id: id} do
      state = %{
        messages: [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}],
        working_dir: File.cwd!(),
        session_cost_usd: 1.25,
        session_input_tokens: 100,
        session_output_tokens: 20
      }

      assert {:noreply, ^state} = Loop.handle_cast({:persist_session, id}, state)

      assert {:ok, restored} = SessionPersistence.load(id)
      assert length(restored) == 2

      spend = SessionPersistence.load_spend(id)
      assert spend.cost_usd == 1.25
      assert spend.input_tokens == 100
    end
  end

  describe "a save that cannot complete LOGS instead of failing silently" do
    test "save_from_state/2 with an unusable state warns with the session id", %{id: id} do
      log =
        capture_log(fn ->
          assert {:error, :invalid_state} = SessionPersistence.save_from_state(id, :not_a_map)
        end)

      assert log =~ id
      assert log =~ "session_persist"
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> (Process.sleep(20) && eventually(fun, attempts - 1))
    end
  end
end
