defmodule OptimalSystemAgent.Agent.Loop.Regulation.PainChannelTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Regulation.PainChannel
  alias OptimalSystemAgent.Events.Bus

  defp sid, do: "pain-channel-#{System.unique_integer([:positive])}"

  defp eventually(fun, checker, attempts \\ 30) do
    value = fun.()

    cond do
      checker.(value) ->
        value

      attempts <= 0 ->
        value

      true ->
        Process.sleep(10)
        eventually(fun, checker, attempts - 1)
    end
  end

  describe "wait-time accumulation" do
    test "take_wait_ms/1 is 0 for a session with nothing recorded" do
      assert PainChannel.take_wait_ms(sid()) == 0
    end

    test "accumulates a :permission_wait Bus event and reads-and-resets on take" do
      session_id = sid()

      Bus.emit(:system_event, %{
        event: :permission_wait,
        session_id: session_id,
        elapsed_ms: 1_500,
        outcome: :timeout
      })

      assert eventually(fn -> PainChannel.take_wait_ms(session_id) end, &(&1 == 1_500)) == 1_500
      assert PainChannel.take_wait_ms(session_id) == 0
    end

    test "accumulates ACROSS multiple waits before being read" do
      session_id = sid()

      for ms <- [200, 300, 500] do
        Bus.emit(:system_event, %{
          event: :permission_wait,
          session_id: session_id,
          elapsed_ms: ms,
          outcome: :allow_once
        })
      end

      assert eventually(fn -> PainChannel.take_wait_ms(session_id) end, &(&1 == 1_000)) == 1_000
    end

    test "ignores unrelated system_event sub-events" do
      session_id = sid()

      Bus.emit(:system_event, %{
        event: :context_pressure,
        session_id: session_id,
        utilization: 50.0
      })

      Process.sleep(30)
      assert PainChannel.take_wait_ms(session_id) == 0
    end
  end

  describe "emission rate limiting" do
    test "the first emission for a session is always allowed" do
      session_id = sid()
      assert PainChannel.should_emit?(session_id, :medium, 60_000)
    end

    test "a repeat at the SAME severity within the window is disallowed" do
      session_id = sid()
      PainChannel.record_emit(session_id, :medium)
      refute PainChannel.should_emit?(session_id, :medium, 60_000)
    end

    test "a repeat at the same severity is allowed once the window elapses" do
      session_id = sid()
      PainChannel.record_emit(session_id, :medium)
      assert PainChannel.should_emit?(session_id, :medium, 0)
    end

    test "a severity INCREASE bypasses the window" do
      session_id = sid()
      PainChannel.record_emit(session_id, :low)
      assert PainChannel.should_emit?(session_id, :high, 60_000)
    end

    test "a severity DECREASE does not bypass the window" do
      session_id = sid()
      PainChannel.record_emit(session_id, :high)
      refute PainChannel.should_emit?(session_id, :low, 60_000)
    end

    test "clear/1 forgets the rate-limit memory" do
      session_id = sid()
      PainChannel.record_emit(session_id, :critical)
      refute PainChannel.should_emit?(session_id, :low, 60_000)

      PainChannel.clear(session_id)

      assert PainChannel.should_emit?(session_id, :low, 60_000)
    end

    test "clear/1 forgets any wait accumulated before it ran" do
      session_id = sid()

      Bus.emit(:system_event, %{
        event: :permission_wait,
        session_id: session_id,
        elapsed_ms: 999,
        outcome: :allow_once
      })

      eventually(fn -> PainChannel.take_wait_ms(session_id) end, &(&1 == 999))

      # Accumulate again, then clear BEFORE anything reads it.
      Bus.emit(:system_event, %{
        event: :permission_wait,
        session_id: session_id,
        elapsed_ms: 111,
        outcome: :allow_once
      })

      eventually(fn -> PainChannel.take_wait_ms(session_id) end, &(&1 == 111))
      PainChannel.clear(session_id)

      assert PainChannel.take_wait_ms(session_id) == 0
    end
  end
end
