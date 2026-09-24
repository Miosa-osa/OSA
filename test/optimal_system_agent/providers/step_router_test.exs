defmodule OptimalSystemAgent.Providers.StepRouterTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.StepRouter

  setup do
    prev_enabled = Application.fetch_env(:optimal_system_agent, :step_routing_enabled)
    prev_pairs = Application.fetch_env(:optimal_system_agent, :step_routing_fast_models)
    Application.put_env(:optimal_system_agent, :step_routing_enabled, true)
    Application.delete_env(:optimal_system_agent, :step_routing_fast_models)

    on_exit(fn ->
      restore(:step_routing_enabled, prev_enabled)
      restore(:step_routing_fast_models, prev_pairs)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:optimal_system_agent, key, v)
  defp restore(key, :error), do: Application.delete_env(:optimal_system_agent, key)

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "step-router-#{System.unique_integer([:positive])}",
        provider: :anthropic,
        model: "claude-sonnet-5",
        iteration: 1,
        tools: [%{name: "file_read"}],
        messages: []
      },
      overrides
    )
  end

  defp with_prior_tools(state, names) do
    tool_calls = Enum.map(names, fn n -> %{id: "call_#{n}", name: n, arguments: %{}} end)
    %{state | messages: [%{role: "assistant", content: "", tool_calls: tool_calls}]}
  end

  describe "disabled by default" do
    test "kept on strong model when step routing is off" do
      Application.put_env(:optimal_system_agent, :step_routing_enabled, false)

      state = base_state() |> with_prior_tools(["file_read"])
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :disabled
    end
  end

  describe "turn start" do
    test "iteration 0 always stays on the strong model" do
      state = base_state(%{iteration: 0}) |> with_prior_tools(["file_read"])
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :turn_start
    end
  end

  describe "thinking continuity" do
    test "an unreplayed signed thinking block forces the strong model" do
      state =
        base_state(%{
          messages: [
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{id: "c1", name: "file_read", arguments: %{}}],
              thinking_blocks: [%{type: "thinking", thinking: "...", signature: "sig"}]
            }
          ]
        })

      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :thinking_continuity
    end
  end

  describe "no fast pairing configured" do
    test "an unpaired provider stays on the strong model" do
      state =
        base_state(%{provider: :groq, model: "llama-3.3-70b"})
        |> with_prior_tools(["file_read"])

      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :no_fast_pairing
    end
  end

  describe "mechanical tool mix" do
    test "all read-only tools route to the paired fast model" do
      state = base_state() |> with_prior_tools(["file_read", "file_grep"])
      decision = StepRouter.decide(state)

      assert decision.route == :fast
      assert decision.provider == :anthropic
      assert decision.model == "claude-haiku-4-5"
      assert decision.reason == :mechanical_tool_mix
    end

    test "ollama_cloud pairs glm-5.2:cloud with the flash counterpart" do
      state =
        base_state(%{provider: :ollama_cloud, model: "glm-5.2:cloud"})
        |> with_prior_tools(["file_grep"])

      decision = StepRouter.decide(state)

      assert decision.route == :fast
      assert decision.model == "glm-5.3-flash:cloud"
    end

    test "an operator-configured pairing overrides the built-in default" do
      Application.put_env(:optimal_system_agent, :step_routing_fast_models, %{
        anthropic: "claude-haiku-4-5-custom"
      })

      state = base_state() |> with_prior_tools(["file_read"])
      decision = StepRouter.decide(state)

      assert decision.model == "claude-haiku-4-5-custom"
    end
  end

  describe "risky/write tool mix never routes" do
    test "a single write tool in the mix keeps the strong model" do
      state = base_state() |> with_prior_tools(["file_read", "file_edit"])
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :risky_tool_mix
    end

    test "bash / shell_execute keeps the strong model" do
      state = base_state() |> with_prior_tools(["shell_execute"])
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :risky_tool_mix
    end
  end

  describe "no prior tool evidence" do
    test "an iteration with no prior tool call stays strong" do
      state = base_state(%{messages: [%{role: "user", content: "hi"}]})
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :no_prior_tools
    end
  end

  describe "ambiguous (unclassified) tool mix" do
    test "defaults to the strong model when there is no budget pressure" do
      # `OptimalSystemAgent.Budget` ships with no daily/monthly cap configured
      # by default, so `check_budget/0` never reports `:over_limit` in this
      # environment regardless of whether the GenServer happens to be running
      # — making this assertion deterministic without touching the shared,
      # application-wide Budget singleton (also exercised by
      # `test/agent/budget_test.exs` and `test/agent/cost_tracker_test.exs`).
      state = base_state() |> with_prior_tools(["file_read", "unknown_future_tool"])
      decision = StepRouter.decide(state)

      assert decision.route == :strong
      assert decision.reason == :ambiguous_tool_mix
    end
  end

  describe "budget_critical?/1 integration against the real Budget singleton" do
    test "an unclassified tool mix routes to fast once the shared Budget singleton is over its cap" do
      # Exercises the REAL, application-wide `OptimalSystemAgent.Budget`
      # GenServer rather than a stand-in — deliberately, since a stub would
      # only prove StepRouter calls a mock, not that it agrees with the
      # already-shipped budget tracker's own `:over_limit` contract. Guarded:
      # skipped (not failed) when the singleton is not running in this test
      # environment.
      case Process.whereis(OptimalSystemAgent.Budget) do
        nil ->
          :ok

        pid ->
          prior = :sys.get_state(pid)

          try do
            :sys.replace_state(pid, fn s -> %{s | daily_limit: 0.000001, daily_spent: 1.0} end)

            state = base_state() |> with_prior_tools(["file_read", "unknown_future_tool"])
            decision = StepRouter.decide(state)

            assert decision.route == :fast
            assert decision.reason == :budget_pressure
          after
            :sys.replace_state(pid, fn _ -> prior end)
          end
      end
    end
  end

  describe "apply/2 and restore" do
    test "fast decision temporarily overrides provider/model then restores" do
      state = base_state() |> with_prior_tools(["file_read"])
      decision = StepRouter.decide(state)
      assert decision.route == :fast

      {call_state, restore} = StepRouter.apply(state, decision)
      assert call_state.model == "claude-haiku-4-5"
      assert call_state.provider == :anthropic

      restored = restore.(call_state)
      assert restored.model == state.model
      assert restored.provider == state.provider
    end

    test "strong decision is a no-op passthrough" do
      state = base_state(%{iteration: 0})
      decision = StepRouter.decide(state)
      assert decision.route == :strong

      {call_state, restore} = StepRouter.apply(state, decision)
      assert call_state == state
      assert restore.(call_state) == state
    end
  end

  describe "mechanical?/1 and all_mechanical?/1" do
    test "classifies the allow-listed tools" do
      assert StepRouter.mechanical?("file_read")
      assert StepRouter.mechanical?("file_grep")
      refute StepRouter.mechanical?("file_edit")
      refute StepRouter.mechanical?("shell_execute")
    end

    test "all_mechanical?/1 requires every name to be on the allow-list" do
      assert StepRouter.all_mechanical?(["file_read", "file_glob"])
      refute StepRouter.all_mechanical?(["file_read", "bash"])
      refute StepRouter.all_mechanical?([])
    end
  end
end
