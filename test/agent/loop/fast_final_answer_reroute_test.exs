defmodule OptimalSystemAgent.Agent.Loop.FastFinalAnswerRerouteTest do
  @moduledoc """
  `StepRouter` only ever routes on evidence from the PREVIOUS step — a run of
  mechanical tool calls — so it cannot know in advance whether the fast
  model's very next move will be another read or a final answer. When it is
  a final answer, the spec is unconditional: the final answer stays on the
  strong model. This proves the backstop end to end, through a real
  `ReactLoop.run/1`, not just the routing decision in isolation.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Test.StepRerouteProvider

  @provider :step_reroute_mock
  @fast_model "step-reroute-fast"
  @strong_model "step-reroute-strong"

  setup do
    prev_enabled = Application.fetch_env(:optimal_system_agent, :step_routing_enabled)
    prev_pairs = Application.fetch_env(:optimal_system_agent, :step_routing_fast_models)
    prev_max_iter = Application.fetch_env(:optimal_system_agent, :max_iterations)

    Application.put_env(:optimal_system_agent, :step_routing_enabled, true)

    Application.put_env(:optimal_system_agent, :step_routing_fast_models, %{
      @provider => @fast_model
    })

    Application.put_env(:optimal_system_agent, :max_iterations, 8)

    StepRerouteProvider.reset()
    :ok = Providers.register_provider(@provider, StepRerouteProvider)

    on_exit(fn ->
      restore(:step_routing_enabled, prev_enabled)
      restore(:step_routing_fast_models, prev_pairs)
      restore(:max_iterations, prev_max_iter)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:optimal_system_agent, key, v)
  defp restore(key, :error), do: Application.delete_env(:optimal_system_agent, key)

  defp base_state(sid) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid,
      provider: @provider,
      model: @strong_model,
      iteration: 0,
      auto_continues: 0,
      overflow_retries: 0,
      messages: [%{role: "user", content: "do the thing"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  test "a fast-routed final answer is discarded and re-answered by the strong model" do
    sid = "fast-reroute-#{System.unique_integer([:positive])}"
    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        if payload.data[:event] == :fast_final_answer_reroute and
             payload.data[:session_id] == sid do
          send(test_pid, {:reroute, payload.data})
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)

    {response, _final_state} = ReactLoop.run(base_state(sid))

    # Call 1 (strong, turn start) asked for a tool. Call 2 (routed fast, on
    # the mechanical evidence from call 1) answered with no tool calls — that
    # answer must be discarded. Call 3 is the strong re-ask, and ITS answer is
    # what the user actually sees.
    assert StepRerouteProvider.calls() == 3

    assert response == StepRerouteProvider.strong_answer()
    refute response == StepRerouteProvider.fast_answer()
    refute String.contains?(response, "FAST_MODEL_ANSWER")

    # The reroute is logged, not silent: which fast pairing was discarded and
    # which strong model actually answered, plus the extra call's cost.
    assert_receive {:reroute, data}, 2_000
    assert data.fast_provider == to_string(@provider)
    assert data.fast_model == @fast_model
    assert data.strong_provider == to_string(@provider)
    assert data.strong_model == @strong_model
    assert is_number(data.cost_usd)
  end
end
