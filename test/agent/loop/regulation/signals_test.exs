defmodule OptimalSystemAgent.Agent.Loop.Regulation.SignalsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Regulation.PainChannel
  alias OptimalSystemAgent.Agent.Loop.Regulation.Signals

  defp sid, do: "signals-#{System.unique_integer([:positive])}"

  defp tc(name, args, id \\ "call_1"), do: %{id: id, name: name, arguments: args}

  describe "probe_streak/1 (via collect/3)" do
    test "counts trailing occurrences of the same identical-call windowed entry" do
      key = {"file_read", :erlang.phash2(%{"path" => "x"})}

      state = %{
        session_id: sid(),
        windowed_call_keys: [
          {key, :erlang.phash2("same body"), true},
          {key, :erlang.phash2("same body"), true},
          {key, :erlang.phash2("same body"), true}
        ]
      }

      signals = Signals.collect([], [], state)
      assert signals.probe_streak == 3
      assert signals.probe_tool == "file_read"
    end

    test "a differing result partitions the count (matches IdenticalCall's own rule)" do
      key = {"file_read", :erlang.phash2(%{"path" => "x"})}

      state = %{
        session_id: sid(),
        windowed_call_keys: [
          {key, :erlang.phash2("old body"), true},
          {key, :erlang.phash2("new body"), true}
        ]
      }

      assert Signals.collect([], [], state).probe_streak == 1
    end

    test "no windowed history reads as zero" do
      assert Signals.collect([], [], %{session_id: sid()}).probe_streak == 0
    end
  end

  describe "reasoning_overflow_ms/2 (via collect/3)" do
    test "flags a slow, tool-call-free generation" do
      state = %{session_id: sid(), last_generation_ms: 90_000}
      assert Signals.collect([], [], state).reasoning_overflow_ms == 90_000
    end

    test "does not flag a fast reasoning-only generation" do
      state = %{session_id: sid(), last_generation_ms: 5_000}
      assert Signals.collect([], [], state).reasoning_overflow_ms == nil
    end

    test "does not flag a slow generation that DID carry tool calls" do
      state = %{session_id: sid(), last_generation_ms: 90_000}
      calls = [tc("shell_execute", %{"command" => "pwd"})]
      assert Signals.collect([], calls, state).reasoning_overflow_ms == nil
    end
  end

  describe "no_disk_change?/1 (via collect/3)" do
    test "true when the only call was a read" do
      calls = [tc("file_read", %{"path" => "/tmp/x"})]
      results = [{hd(calls), {%{}, "file contents"}}]
      assert Signals.collect(results, calls, %{session_id: sid()}).no_disk_change? == true
    end

    test "false when an edit call actually succeeded" do
      calls = [tc("file_edit", %{"path" => "/tmp/x"})]
      results = [{hd(calls), {%{}, "Edited /tmp/x"}}]
      assert Signals.collect(results, calls, %{session_id: sid()}).no_disk_change? == false
    end

    test "true when the edit call errored (no real write happened)" do
      calls = [tc("file_edit", %{"path" => "/tmp/x"})]
      results = [{hd(calls), {%{}, "Error: permission denied"}}]
      assert Signals.collect(results, calls, %{session_id: sid()}).no_disk_change? == true
    end
  end

  describe "cost_this_turn_usd (via collect/3)" do
    test "reports the delta since the turn's baseline, not the session total" do
      state = %{
        session_id: sid(),
        session_cost_usd: 1.75,
        regulation_turn_baseline_cost_usd: 1.50
      }

      assert_in_delta Signals.collect([], [], state).cost_this_turn_usd, 0.25, 0.0001
    end

    test "never goes negative" do
      state = %{session_id: sid(), session_cost_usd: 1.0, regulation_turn_baseline_cost_usd: 1.5}
      assert Signals.collect([], [], state).cost_this_turn_usd == 0.0
    end
  end

  describe "wait_ms (via collect/3)" do
    test "reads and resets PainChannel's per-session accumulator" do
      session_id = sid()
      PainChannel.clear(session_id)

      OptimalSystemAgent.Events.Bus.emit(:system_event, %{
        event: :permission_wait,
        session_id: session_id,
        elapsed_ms: 4_200,
        outcome: :allow_once
      })

      # `Bus.emit/3` dispatches through a supervised Task, and PainChannel's
      # handler runs in a second one — poll briefly rather than assume a fixed
      # delay is always enough.
      assert eventually(fn -> PainChannel.take_wait_ms(session_id) end, 4_200)
      # Reset on read.
      assert Signals.collect([], [], %{session_id: session_id}).wait_ms == 0
    end

    defp eventually(fun, expected, attempts \\ 20) do
      value = fun.()

      cond do
        value == expected ->
          value

        attempts <= 0 ->
          value

        true ->
          Process.sleep(10)
          eventually(fun, expected, attempts - 1)
      end
    end
  end
end
