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
