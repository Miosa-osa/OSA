defmodule OptimalSystemAgent.ObservabilityTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Events

  describe "new_turn_id/0" do
    test "mints a prompt.id-style correlation id" do
      id = Observability.new_turn_id()
      assert String.starts_with?(id, "prompt_")
    end

    test "is unique across calls" do
      ids = for _ <- 1..50, do: Observability.new_turn_id()
      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "annotate/2" do
    test "threads session_id + turn_id (correlation) into the event envelope" do
      state = %{session_id: "sess-42", turn_id: "prompt_abc"}
      env = Observability.annotate(state)

      assert env[:session_id] == "sess-42"
      assert env[:correlation_id] == "prompt_abc"
      assert env[:source] == "agent.loop"
    end

    test "extra opts override defaults (e.g. source)" do
      state = %{session_id: "s", turn_id: "t"}
      env = Observability.annotate(state, source: "agent.tool_executor")
      assert env[:source] == "agent.tool_executor"
    end

    test "tolerates a state without correlation fields" do
      env = Observability.annotate(%{})
      assert env[:session_id] == nil
      assert env[:correlation_id] == nil
    end
  end

  describe "lifecycle emit helpers" do
    test "return :ok and never raise on a bare state map" do
      state = %{session_id: "sess-x", turn_id: "prompt_x", model: "m", iteration: 1}
      assert Observability.turn_start(state) == :ok
      assert Observability.turn_end(state, "done") == :ok
      assert Observability.compaction(state, %{strategy: :proactive}) == :ok
      assert Observability.emit(:system_event, %{event: :error}, state) == :ok
    end
  end

  describe "unobserved_background_count/1 (recorded on both ends of every turn)" do
    # The condition `VerificationGate` clause 0 refuses: a turn ending with
    # background work in flight. Measured at 9/20 model failures and 0/37
    # solves on `bench/terminalbench/runs/osa-tb20-full89-f6981b61`. It is on
    # the wire next to `effort` and `reasoning` because every defect found in
    # that arm had been silent, and this one must not be the next.
    defmodule StubBackground do
      def list,
        do: [
          %{id: "bg_1", command: "pytest", session_id: "obs-bg", status: :running},
          %{id: "bg_2", command: "make", session_id: "obs-bg", status: :done},
          %{id: "bg_3", command: "sleep 9", session_id: "other", status: :running}
        ]
    end

    defmodule BrokenBackground do
      def list, do: raise("registry is down")
    end

    setup do
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :background_manager) end)
      :ok
    end

    test "counts only this session's still-running jobs" do
      Application.put_env(:optimal_system_agent, :background_manager, StubBackground)
      assert Observability.unobserved_background_count(%{session_id: "obs-bg"}) == 1
      assert Observability.unobserved_background_count(%{session_id: "other"}) == 1
      assert Observability.unobserved_background_count(%{session_id: "nobody"}) == 0
    end

    test "reads as 0 when it cannot be resolved — telemetry never fabricates a fire" do
      Application.put_env(:optimal_system_agent, :background_manager, BrokenBackground)
      assert Observability.unobserved_background_count(%{session_id: "obs-bg"}) == 0
      assert Observability.unobserved_background_count(%{}) == 0
    end
  end

  describe "structured events reach the durable per-session stream (correlated)" do
    @tag :integration
    test "emitted lifecycle event lands in the session stream carrying the turn_id" do
      if Process.whereis(OptimalSystemAgent.Events.Bus) do
        sid = "obs-stream-#{System.unique_integer([:positive])}"
        {:ok, _pid} = Events.Stream.start_link(sid)

        state = %{session_id: sid, turn_id: "prompt_corr_1", model: "m", turn_count: 1}
        Observability.turn_start(state)

        event = wait_for_event(sid)
        assert event
        assert event.session_id == sid
        assert event.correlation_id == "prompt_corr_1"
      end
    end
  end

  defp wait_for_event(sid, attempts \\ 40)
  defp wait_for_event(_sid, 0), do: nil

  defp wait_for_event(sid, attempts) do
    case Events.Stream.events(sid) do
      {:ok, [ev | _]} ->
        ev

      _ ->
        Process.sleep(25)
        wait_for_event(sid, attempts - 1)
    end
  end
end
