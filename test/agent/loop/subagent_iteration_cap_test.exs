defmodule OptimalSystemAgent.Agent.Loop.SubagentIterationCapTest do
  @moduledoc """
  A delegated subagent can carry a PER-RUN iteration cap (its agent def's
  `max_iterations`, e.g. `researcher` at 30) that wins over the global,
  effectively-unbounded default. This is the guard against a single researcher
  crawling 197 pages / 28M tokens in one turn: at the cap the loop runs the
  forced wrap-up (a real "what I found / what remains" handoff) and emits
  `:max_iterations_reached`, rather than running to the 1,000,000 ceiling.

  Proves the wiring end to end at the enforcement point: `react_loop` reads
  `state.max_iterations` ahead of the global `:max_iterations` app env.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    # Global cap deliberately HIGH, so anything that stops early can only be the
    # per-run cap winning over it.
    Application.put_env(:optimal_system_agent, :max_iterations, 100)

    on_exit(fn ->
      for {k, v} <- [default_provider: prev.provider, max_iterations: prev.max_iter] do
        if is_nil(v),
          do: Application.delete_env(:optimal_system_agent, k),
          else: Application.put_env(:optimal_system_agent, k, v)
      end
    end)

    :ok
  end

  defp state(session, extra) do
    MockProvider.reset_round_trips()

    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      messages: [%{role: "user", content: "research the whole landscape"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
    |> Map.merge(extra)
  end

  test "a per-run max_iterations of 1 stops the loop at the cap, beating the global 100" do
    session = "cap-#{System.unique_integer([:positive])}"

    {response, final} = ReactLoop.run(state(session, %{max_iterations: 1}))

    # The loop halted at the PER-RUN cap (1), not the global (100), and the halt
    # is the forced wrap-up handoff, not a silent stop.
    assert Map.get(final, :iteration) == 1
    assert response =~ ~r/used all 1 iteration/i,
           "expected the forced wrap-up at the per-run cap; got: #{inspect(response)}"
  end

  test "with NO per-run cap the same run finishes normally under the global (100)" do
    session = "nocap-#{System.unique_integer([:positive])}"

    {response, _final} = ReactLoop.run(state(session, %{}))

    # It runs to the mock's natural end, NOT an iteration-cap wrap-up.
    refute response =~ ~r/used all .* iteration/i,
           "no per-run cap was set, so the loop must not hit an iteration cap"
  end
end
