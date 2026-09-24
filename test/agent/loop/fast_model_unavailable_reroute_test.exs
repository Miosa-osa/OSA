defmodule OptimalSystemAgent.Agent.Loop.FastModelUnavailableRerouteTest do
  @moduledoc """
  "If a pairing's fast model isn't available for the user's provider or
  credentials, routing silently stays on the strong model and logs why
  once." `LLMClient.llm_chat_stream/3`'s own retry/backoff has already
  exhausted itself on the fast model by the time `ReactLoop` sees the error
  here, so a fast-routed call that fails must not surface as a user-visible
  turn failure — the strong model answers instead, and a non-retryable
  reason (auth/model-not-found style) additionally disables the pairing for
  the rest of the run so routing stops wasting attempts (and redo latency)
  on it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Providers.StepRouter
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
    StepRouter.clear_unavailable(@provider, @fast_model)
    :ok = Providers.register_provider(@provider, StepRerouteProvider)

    on_exit(fn ->
      restore(:step_routing_enabled, prev_enabled)
      restore(:step_routing_fast_models, prev_pairs)
      restore(:max_iterations, prev_max_iter)
      StepRouter.clear_unavailable(@provider, @fast_model)
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

  test "a non-retryable fast-model failure is silently answered by the strong model and marks the pairing unavailable" do
    sid = "fast-unavailable-#{System.unique_integer([:positive])}"
    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        case payload.data[:event] do
          :fast_final_answer_reroute ->
            if payload.data[:session_id] == sid, do: send(test_pid, {:reroute, payload.data})

          :fast_model_marked_unavailable ->
            send(test_pid, {:marked, payload.data})

          _ ->
            :ok
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)

    refute StepRouter.unavailable?(@provider, @fast_model)

    # An auth failure — a structured, non-retryable reason (see
    # `FallbackChain.retryable_error?/1`'s `@auth_config_categories`), never
    # worth retrying the same key against. Armed for exactly 2 attempts:
    # Registry's own same-provider resilience makes a native stream attempt
    # AND (since a non-transient reason is only classified AFTER that
    # fallback, not before it) one same-provider sync-fallback attempt for
    # this ONE fast-routed step before giving up and surfacing the error to
    # ReactLoop. Arming MORE than that would also fail the strong model's
    # own re-ask below, which must succeed.
    StepRerouteProvider.fail_calls({:http_error, 401, "invalid x-api-key"}, 2)

    {response, _final_state} = ReactLoop.run(base_state(sid))

    # The turn still completes with a real answer — the fast model's
    # failure never surfaced to the user.
    assert response == StepRerouteProvider.strong_answer()

    assert_receive {:reroute, data}, 2_000
    assert data.fast_provider == to_string(@provider)
    assert data.fast_model == @fast_model
    assert data.reroute_reason == :fast_model_error

    assert_receive {:marked, marked}, 2_000
    assert marked.provider == to_string(@provider)
    assert marked.model == @fast_model

    assert StepRouter.unavailable?(@provider, @fast_model)
  end

  test "once marked unavailable, later steps stay on the strong model without attempting the fast one again" do
    sid = "fast-unavailable-sticky-#{System.unique_integer([:positive])}"
    StepRouter.mark_unavailable(@provider, @fast_model, {:http_error, 401, "invalid x-api-key"})

    decision =
      StepRouter.decide(%{
        session_id: sid,
        provider: @provider,
        model: @strong_model,
        iteration: 1,
        tools: [],
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [%{id: "c1", name: "file_read", arguments: %{}}]
          }
        ]
      })

    assert decision.route == :strong
    assert decision.reason == :fast_model_unavailable
  end
end
