defmodule OptimalSystemAgent.Agent.Orchestrator.DispatchTimingProbeTest do
  @moduledoc """
  The instrument that found the bug, kept as the test that stops it returning.

  Records the wall-clock arrival of every event a background subagent puts on
  the parent session topic. The original trace, before any fix, was:

        17ms  background_agent_started
        22ms  orchestrator_agent_started
      7196ms  orchestrator_agent_progress     <- 7.17 SECONDS of nothing
     12197ms  orchestrator_agent_progress
     ...

  and that is the FLOOR: a mock provider, a trivial task, a temp-dir workspace
  and no worktree. On a real repo (worktree isolation copies the tree), with a
  real model's time-to-first-token, the same stretch is minutes — which is
  exactly the window the user could not account for, and exactly the window the
  TUI filled with "state unknown · last signal 4m ago" after its own 90-second
  local timer expired.

  The invariant: **a long silence must be labelled.** Any gap on the dispatch
  path longer than `@max_unlabelled_gap_ms` must be preceded by a phase frame
  saying what the agent is doing. This does not require the silence to be short
  — a subagent legitimately waiting on a slow model should not be hurried, and
  there is no timeout anywhere in this fix. It requires the silence to be
  explained.

  Set `OSA_TIMING_TRACE=1` to print the full trace.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  # Comfortably under the TUI's 90s `STALE_SECS`, so a gap that would ever reach
  # the user as an unexplained row fails here first.
  @max_unlabelled_gap_ms 2_000

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    :ok
  end

  test "no silent stretch on the dispatch path is left unexplained" do
    parent = "timing-probe-" <> Integer.to_string(System.unique_integer([:positive]))
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

    # Provider latency stands in for a real model's time-to-first-token, which is
    # where most of the real-world gap lives.
    Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 3_000)

    t0 = System.monotonic_time(:millisecond)

    {:ok, agent_id} =
      Orchestrator.run_background(parent, %{
        task: "say hello",
        role: "tester",
        tier: :specialist,
        model: "mock-model-1.0",
        provider: :mock,
        working_dir: System.tmp_dir!()
      })

    trace = collect(t0, [], 30_000)

    if System.get_env("OSA_TIMING_TRACE") do
      IO.puts("\n=== dispatch trace for #{agent_id} ===")

      Enum.each(trace, fn {ms, label} ->
        IO.puts(String.pad_leading("#{ms}ms", 9) <> "  " <> label)
      end)

      IO.puts("")
    end

    assert trace != [], "the parent saw nothing at all"

    # Every long gap must OPEN with a phase — i.e. the last thing the parent
    # heard before falling silent was a statement of what the agent is doing.
    unexplained =
      trace
      |> Enum.zip(Enum.drop(trace, 1))
      |> Enum.filter(fn {{a_ms, label}, {b_ms, _}} ->
        b_ms - a_ms > @max_unlabelled_gap_ms and label != "background_agent_phase"
      end)
      |> Enum.map(fn {{a_ms, label}, {b_ms, _}} ->
        "#{b_ms - a_ms}ms after #{label} (@#{a_ms}ms)"
      end)

    assert unexplained == [],
           "a silence longer than #{@max_unlabelled_gap_ms}ms was not preceded by a phase " <>
             "saying what the agent is doing — this is the shape that reaches the user as " <>
             "\"state unknown\": #{inspect(unexplained)}\nfull trace: #{inspect(trace)}"
  end

  defp collect(t0, acc, budget) do
    receive do
      {:osa_event, ev} ->
        ms = System.monotonic_time(:millisecond) - t0

        label =
          case {ev[:type], ev[:event]} do
            {:system_event, e} when not is_nil(e) -> to_string(e)
            {nil, e} when not is_nil(e) -> to_string(e)
            {t, nil} -> to_string(t)
            {t, e} -> "#{t}/#{e}"
          end

        acc = acc ++ [{ms, label}]

        if label in ["background_agent_completed", "background_agent_failed"],
          do: acc,
          else: collect(t0, acc, budget)
    after
      budget -> acc
    end
  end
end
