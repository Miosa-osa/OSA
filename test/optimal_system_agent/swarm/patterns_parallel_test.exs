defmodule OptimalSystemAgent.Swarm.PatternsParallelTest do
  @moduledoc """
  Wave 1 — a swarm must not report work that never happened.

  `parallel/3` mapped `{:exit, :timeout}` to `{:ok, "[Agent timed out]"}`: a
  killed agent that produced nothing came back wearing the same `{:ok, _}` shape
  as an agent that succeeded, so completion tallies counted it and the
  synthesizer was handed a placeholder string as if it were output. The
  equivalent classification already existed on the delegate path.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Swarm.Patterns

  defp cfg(task), do: %{task: task, role: "tester"}

  test "a timed-out agent is an error, never an {:ok, _} result" do
    configs = [cfg("fast"), cfg("hangs"), cfg("also fast")]

    runner = fn
      %{task: "hangs"} -> Process.sleep(:infinity)
      %{task: t} -> {:ok, "did #{t}"}
    end

    {:ok, results} = Patterns.parallel("swarm-test-1", configs, runner: runner, timeout: 150)

    assert [{:ok, "did fast"}, timed_out, {:ok, "did also fast"}] = results

    # THE assertion: the timed-out slot must not be an success-shaped result, and
    # must carry no fabricated output text.
    refute match?({:ok, _}, timed_out), "a timeout was laundered into success: #{inspect(results)}"
    assert timed_out == {:error, :timeout}

    # Nothing anywhere in the results invents work for the killed agent.
    refute Enum.any?(results, &match?({:ok, "[Agent timed out]"}, &1))

    # And a caller counting completions the way the orchestrator does sees 2, not 3.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
  end

  test "an ordinary crash is also an error, and order is preserved" do
    configs = [cfg("a"), cfg("boom"), cfg("c")]

    runner = fn
      %{task: "boom"} -> exit(:kaboom)
      %{task: t} -> {:ok, t}
    end

    {:ok, results} = Patterns.parallel("swarm-test-2", configs, runner: runner, timeout: 5_000)

    assert [{:ok, "a"}, {:error, reason}, {:ok, "c"}] = results
    assert reason =~ "kaboom"
  end

  test "concurrency is capped at the delegate cap instead of the config count" do
    cap = Orchestrator.delegate_concurrency_cap()
    n = cap * 3

    # Each runner bumps a shared peak-concurrency counter, holds briefly so
    # overlap is observable, then drops it.
    {:ok, counter} = Agent.start_link(fn -> %{live: 0, peak: 0} end)

    runner = fn %{task: t} ->
      Agent.update(counter, fn %{live: l, peak: p} ->
        %{live: l + 1, peak: max(p, l + 1)}
      end)

      Process.sleep(40)
      Agent.update(counter, fn s -> %{s | live: s.live - 1} end)
      {:ok, t}
    end

    configs = Enum.map(1..n, fn i -> cfg("t#{i}") end)

    {:ok, results} =
      Patterns.parallel("swarm-test-3", configs, runner: runner, timeout: 10_000)

    peak = Agent.get(counter, & &1.peak)
    Agent.stop(counter)

    # Every config still runs — the cap queues, it does not drop work.
    assert length(results) == n
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # `max_concurrency: length(configs)` would let all `n` run at once.
    assert peak <= cap, "peak concurrency #{peak} exceeded the delegate cap #{cap}"
  end
end
