defmodule OptimalSystemAgent.Agent.Loop.TelemetryPerIterationTest do
  @moduledoc """
  Regression test for the frozen mid-turn context meter.

  Root cause: `Telemetry.emit_context_pressure/1` was only called at turn
  boundaries (`Loop.run_and_reply/1` / the plan-reply path), never inside a
  single ReAct turn. A turn that makes many tool calls (e.g. reading a dozen
  files) grows `state.messages` — and therefore the char/word fallback
  estimate `Compactor.estimate_tokens/1` — on every iteration, but nothing
  told the TUI, so the status-bar meter appeared frozen until the whole turn
  finished.

  The fix hooks `ReactLoop`'s tool-calls branch (`handle_result/3`, the
  `%{tool_calls: tool_calls}` clause) right after this iteration's tool
  results are folded into `state.messages` and before the next model call /
  recursive `run(state)`. This test proves the underlying mechanism the fix
  relies on: calling `emit_context_pressure/1` once per iteration, with the
  freshly-grown message list each time, produces multiple Bus
  `:context_pressure` events whose `estimated_tokens` / `utilization` climb
  monotonically as tool results accumulate — i.e. the meter would visibly
  move mid-turn instead of staying flat until the final turn-boundary emit.

  This is a focused unit test on `Telemetry.emit_context_pressure/1` (the
  function the new call site invokes) rather than a full `ReactLoop.run/1`
  integration test, because driving `ReactLoop.run/1` through several
  simulated tool-calling iterations requires mocking the LLM client and tool
  orchestrator end-to-end; the seam itself (see
  `lib/optimal_system_agent/agent/loop/react_loop.ex`, the
  `tool_messages = ... ; state = %{state | messages: ...}` block right before
  the computer_use short-circuit) is a one-line, directly-readable call to
  this same function, so exercising the function's per-call behavior here is
  sufficient to lock in the fix's contract.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Events.Bus

  defp big_tool_result(i) do
    %{
      role: "tool",
      tool_call_id: "call_#{i}",
      content: String.duplicate("some file content line #{i} with real words in it. ", 40)
    }
  end

  defp subscribe_context_pressure(test_pid, session_id) do
    Bus.register_handler(:system_event, fn event_map ->
      data = event_map[:data] || event_map["data"]

      if is_map(data) and data[:event] == :context_pressure and data[:session_id] == session_id do
        send(test_pid, {:ctx_pressure, data})
      end
    end)
  end

  test "emitting once per ReAct iteration produces multiple climbing events for one turn" do
    session_id = "ctx-per-iter-#{:erlang.unique_integer([:positive])}"
    ref = subscribe_context_pressure(self(), session_id)

    base_state = %{
      session_id: session_id,
      model: "gpt-4o",
      provider: :openai,
      # No provider-reported usage this turn (mirrors glm/Ollama and the
      # common mid-turn case before the next LLM round-trip refreshes it) —
      # forces the char/word fallback estimate, which is exactly what must
      # climb as tool results accumulate.
      last_input_tokens: 0,
      messages: [%{role: "user", content: "read the whole project and summarize it"}]
    }

    # Simulate 4 ReAct iterations of a heavy-reading turn: each iteration
    # appends an assistant tool-call message plus a sizeable tool result,
    # exactly like the real seam does right after
    # `state = %{state | messages: state.messages ++ tool_messages}`.
    iteration_states =
      Enum.scan(1..4, base_state, fn i, acc ->
        %{
          acc
          | messages:
              acc.messages ++
                [
                  %{
                    role: "assistant",
                    content: "",
                    tool_calls: [%{id: "call_#{i}", name: "file_read"}]
                  },
                  big_tool_result(i)
                ]
        }
      end)

    Enum.each(iteration_states, &Telemetry.emit_context_pressure/1)

    events =
      for _ <- 1..4 do
        assert_receive {:ctx_pressure, data}, 1_000
        data
      end

    Bus.unregister_handler(:system_event, ref)

    assert length(events) == 4

    # Bus.emit dispatches through a Task.Supervisor, so events can be
    # DELIVERED out of emission order even though each one carries the
    # correct per-iteration estimate. Sort by estimated_tokens (the char/word
    # estimate of that iteration's message list, which only ever grows) to
    # recover emission order deterministically.
    estimates = events |> Enum.map(& &1[:estimated_tokens]) |> Enum.sort()
    utilizations = events |> Enum.map(& &1[:utilization]) |> Enum.sort()

    # The meter must actually move: each successive iteration's estimate (and
    # therefore utilization) is strictly greater than the previous one, proving
    # the per-iteration emit reflects freshly-added tool results instead of
    # staying pinned until the turn ends.
    assert Enum.uniq(estimates) == estimates
    assert List.first(estimates) > 0
    assert List.last(estimates) > List.first(estimates)

    assert Enum.uniq(utilizations) == utilizations
    assert List.last(utilizations) > List.first(utilizations)
  end
end
