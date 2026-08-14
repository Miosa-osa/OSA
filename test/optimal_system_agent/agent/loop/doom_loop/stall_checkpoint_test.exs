defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.StallCheckpointTest do
  @moduledoc """
  The exhausted-stall checkpoint (diagnosis item A5).

  ## The measured problem

  Under `overdrive` (which the bench driver sets before the first prompt) and
  under an `:auto` tier, `Stall.hard_halt?/1` is false, so an exhausted stall
  fell through to a bare `Logger.warning` and continued. Verified directly
  against the run logs, independently of any tool-argument data:

  | run | "Stall detected" | "Graded escalation" | halts |
  |---|---:|---:|---:|
  | schemelike-metacircular-eval__DYYw2S6 | 95 | 3 | 0 |
  | largest-eigenval__AwHVyR2 | 31 | 3 | 0 |
  | train-fasttext__jSwcZxA | 22 | 3 | 0 |
  | db-wal-recovery__8Fk8MdS | 10 | 3 | 0 |

  Escalation caps at 3 nudges; everything after that produced no action at all.
  Driver telemetry agrees, reporting `stall_detector` counts of 4, 13, 18, 25,
  63 and higher across other runs. **A detector that fires 95 times and changes
  nothing is worse than no detector: the logs assert that the system noticed
  while the system did nothing.**

  ## What must NOT change

  It still never halts in autonomous mode. `path-tracing` was solved at 175
  turns; the diagnosis is explicit that hard-halting on stall is the
  "give up earlier" trap. These tests pin that.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Stall
  alias OptimalSystemAgent.Events.Bus

  # A window's worth of calls that stalls: no write/edit, no investigation tool,
  # and no newly-distinct tool.
  @stalling_tool "ask_user"

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "stall-checkpoint-test",
        messages: [],
        permission_mode: :overdrive,
        distinct_tools_seen: MapSet.new([@stalling_tool]),
        recent_tool_names: List.duplicate(@stalling_tool, 12),
        distinct_count_log: List.duplicate(1, 13),
        # Graded escalation already exhausted — the state the real runs spent
        # hundreds of detections in.
        graded_escalation_count: Escalation.max_steps()
      },
      overrides
    )
  end

  defp tick(state) do
    calls = [%{name: @stalling_tool, arguments: %{}}]
    Stall.check(calls, Map.put(state, :escalated_this_tick, false))
  end

  # Drive `n` consecutive exhausted-stall detections.
  defp tick_n(state, n) do
    Enum.reduce(1..n, state, fn _i, st ->
      {:ok, st} = tick(st)
      st
    end)
  end

  describe "it never halts in autonomous mode" do
    test "an exhausted stall under :overdrive continues" do
      assert {:ok, _state} = tick(base_state())
    end

    test "an exhausted stall under the :auto tier continues" do
      state = base_state(%{permission_mode: :default, permission_tier: :auto})
      assert {:ok, _state} = tick(state)
    end

    test "hundreds of consecutive detections never produce a halt" do
      # The 95-detection run, and then some. A single halt here would convert a
      # long-but-recoverable run into a failure.
      state =
        Enum.reduce(1..300, base_state(), fn i, st ->
          case tick(st) do
            {:ok, st} -> st
            {:halt, msg, _} -> flunk("halted at detection #{i}: #{msg}")
          end
        end)

      assert Map.get(state, :stall_checkpoint_count) == 300
    end
  end

  describe "it records every detection" do
    setup do
      # `Bus` has no subscribe/1 — handlers are functions, and `emit/3`
      # dispatches to them. Forward the ones we care about to the test process.
      #
      # `dispatch_event/1` (lib/optimal_system_agent/events/bus.ex) looks up
      # registered handlers in its ETS table at *dispatch* time, inside an
      # async `Task` several hops removed from the original `emit/3` call —
      # not at emit time. `async: false` only serializes test *bodies*; it
      # does not wait for a finished test's in-flight dispatch tasks to
      # drain before the next test's `setup` runs. So a still-inflight event
      # emitted by an *earlier* test in this file (e.g. the 24- or
      # 300-detection drives in the sibling `describe` blocks, all of which
      # emit through this exact bus) can be looked up and delivered to
      # *this* test's freshly-registered handler once it lands. Every test
      # in this module shares the literal session id
      # `"stall-checkpoint-test"`, so filtering on session id alone can't
      # tell the two apart — the 24th detection of an unrelated test looks
      # identical to a real detection 24 in this test's own run. Root cause
      # confirmed by observation: a handler that collected exactly 3
      # messages returned `[2, 3, 24]` — a spurious 24 from another test's
      # stream mixed in with 2 genuine detections while detection 1 was
      # still in flight.
      #
      # Give each test in this block its own session id so the handler can
      # filter out any event that did not originate from it, no matter when
      # it happens to arrive.
      session_id = "stall-checkpoint-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      # `Bus.emit/3` wraps the caller's payload in a CloudEvents-shaped envelope
      # and hands the handler the whole envelope, so the emitted map is at `.data`.
      ref =
        Bus.register_handler(:system_event, fn envelope ->
          data = Map.get(envelope, :data, %{})

          if is_map(data) and Map.get(data, :event) == :stall_checkpoint and
               Map.get(data, :session_id) == session_id do
            send(test_pid, {:checkpoint, data})
          end

          :ok
        end)

      on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
      {:ok, session_id: session_id}
    end

    test "each exhausted stall emits a stall_checkpoint carrying its count", %{
      session_id: session_id
    } do
      tick_n(base_state(%{session_id: session_id}), 3)

      events = drain_checkpoints(3)

      assert length(events) == 3,
             "every detection must be recorded, or '95 detections' stays unknowable"

      # Sorted: `Bus.emit/3` dispatches each handler in its own supervised task,
      # so delivery order is not guaranteed (observed: 2, 1, 3).
      assert events |> Enum.map(& &1.detection) |> Enum.sort() == [1, 2, 3]
      assert Enum.all?(events, &(&1.session_id == session_id))
      assert Enum.all?(events, &is_integer(&1.window))
    end

    test "the event says whether a re-plan was injected", %{session_id: session_id} do
      tick_n(base_state(%{session_id: session_id}), 2)
      events = drain_checkpoints(2)

      by_detection =
        events
        |> Enum.map(&{&1.detection, &1.replan_injected})
        |> Enum.sort()

      assert by_detection == [{1, true}, {2, false}]
    end

    # Collects exactly `n` checkpoint events, blocking until each one arrives.
    #
    # `Bus.emit/3` dispatches through three nested `Task.Supervisor.start_child`
    # hops (do_emit -> goldrush router -> handler) before this process's mailbox
    # sees a message (see `lib/optimal_system_agent/events/bus.ex`). The previous
    # implementation waited for a 500ms *quiet gap* after the last message and
    # then assumed delivery was complete — under scheduler load (e.g. this exact
    # file run back-to-back) the 3rd hop can legitimately take longer than
    # 500ms end-to-end, so that gap-based heuristic under-collected and the test
    # failed on a correct system (measured: 1-3 failures per 10-20 runs, always
    # asserting the collected length was short). Waiting for exactly `n`
    # messages removes that guess entirely: correctness no longer depends on
    # inter-arrival timing, only on eventual delivery within a generous
    # per-message bound that only fires on a genuine hang.
    defp drain_checkpoints(n, timeout \\ 5_000) do
      for i <- 1..n do
        receive do
          {:checkpoint, payload} -> payload
        after
          timeout ->
            flunk("timed out waiting for stall_checkpoint ##{i} of #{n} (bus dispatch hung?)")
        end
      end
    end
  end

  describe "it forces a written re-plan, rate-limited" do
    test "the first exhausted stall injects a re-plan directive" do
      {:ok, state} = tick(base_state())

      assert [%{role: "system", content: content}] = state.messages
      assert content =~ "STALL CHECKPOINT 1"
      # It asks for writing, not stopping.
      assert content =~ "the goal, restated"
      assert content =~ "DIFFERENT in kind"
      assert content =~ "You are not being stopped"
    end

    test "it does not inject on every detection" do
      state = tick_n(base_state(), 24)

      assert length(state.messages) == 1,
             "injecting on all 247 detections would add 247 system messages to a " <>
               "transcript whose growth is already the dominant cost term"
    end

    test "it injects again once the interval elapses" do
      state = tick_n(base_state(), 25)
      assert length(state.messages) == 2

      state = tick_n(state, 25)
      assert length(state.messages) == 3
    end

    test "over the worst measured run it produces ~10 re-plans, not 247" do
      state = tick_n(base_state(), 247)
      n = length(state.messages)

      assert n >= 8 and n <= 12,
             "expected roughly one re-plan per 25 detections, got #{n}"
    end

    test "the directive names the tools actually being repeated" do
      state = base_state(%{recent_tool_names: List.duplicate("shell_execute", 12)})
      {:ok, state} = tick(state)

      assert [%{content: content}] = state.messages
      assert content =~ "shell_execute"
    end
  end

  describe "a non-stalled window is untouched" do
    test "a window containing a write is not a stall" do
      state =
        base_state(%{
          recent_tool_names: List.duplicate(@stalling_tool, 11) ++ ["file_write"],
          distinct_tools_seen: MapSet.new([@stalling_tool, "file_write"])
        })

      {:ok, state} = tick(state)
      assert state.messages == []
      refute Map.has_key?(state, :stall_checkpoint_count)
    end

    test "a window containing an investigation is not a stall" do
      state =
        base_state(%{
          recent_tool_names: List.duplicate(@stalling_tool, 11) ++ ["file_read"],
          distinct_tools_seen: MapSet.new([@stalling_tool, "file_read"])
        })

      {:ok, state} = tick(state)
      assert state.messages == []
    end
  end

  describe "interactive mode still hard-halts" do
    setup do
      # Note: `config/config.exs:172` ships `stall_hard_halt: false`, so this
      # branch is dead in every default configuration — the checkpoint is the
      # behaviour everywhere. It is pinned here so that if the flag is ever
      # turned back on, the halt is still the halt and not a checkpoint.
      prior = Application.get_env(:optimal_system_agent, :stall_hard_halt)
      Application.put_env(:optimal_system_agent, :stall_hard_halt, true)
      on_exit(fn -> Application.put_env(:optimal_system_agent, :stall_hard_halt, prior) end)
      :ok
    end

    test "an exhausted stall outside autonomous mode halts as before" do
      state = base_state(%{permission_mode: :default, permission_tier: :workspace})

      assert {:halt, msg, _state} = tick(state)
      assert msg =~ "no forward progress"
      # And it does not also checkpoint — the halt IS the action.
      refute msg =~ "STALL CHECKPOINT"
    end
  end
end
