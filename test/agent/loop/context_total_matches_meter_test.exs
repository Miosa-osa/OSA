defmodule OptimalSystemAgent.Agent.Loop.ContextTotalMatchesMeterTest do
  @moduledoc """
  `/context`'s total and the status-bar meter are one number.

  The meter read the provider-reported size of the LAST request
  (`last_input_tokens`) and nothing else, while `/context` summed its own
  estimate of the whole history. So the two disagreed after every response,
  and neither counted what had been added since the last request — the
  assistant's own reply, tool results folded after it, the user's next message.

  Both now report `last_input_tokens` plus an estimate of the messages appended
  after that request (`Telemetry.context_occupancy/1`), and these tests drive a
  real Loop to prove it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Test.MockProvider

  @reported_input 12_345

  setup do
    prev = %{
      default_provider: Application.get_env(:optimal_system_agent, :default_provider),
      mock_provider_module: Application.get_env(:optimal_system_agent, :mock_provider_module),
      mock_provider_usage: Application.get_env(:optimal_system_agent, :mock_provider_usage)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)

    Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
      input_tokens: @reported_input,
      output_tokens: 10
    })

    MockProvider.reset()

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    session = "ctx-total-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      SessionManager.ensure_loop(session,
        user_id: "test",
        working_dir: File.cwd!(),
        provider: :mock,
        model: "mock-model-1.0"
      )

    on_exit(fn -> SessionManager.cancel(session) end)
    {:ok, session: session}
  end

  defp loop_pid(session) do
    [{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session)
    pid
  end

  test "/context total, get_state and the meter agree and include messages added since the last request",
       %{session: session} do
    assert {:ok, _} = Loop.process_message(session, "hello", timeout: :infinity)

    pid = loop_pid(session)
    state = :sys.get_state(pid)
    assert state.last_input_tokens == @reported_input

    baseline = Map.fetch!(state, :last_input_message_count)
    since = Enum.drop(state.messages, baseline)

    assert since != [],
           "the final assistant reply is appended AFTER the last request, so something " <>
             "must have been added since it"

    expected = @reported_input + Compactor.estimate_tokens(since)
    assert Telemetry.context_occupancy(state) == expected

    assert {:ok, budget} = SessionManager.context_budget(session)
    assert budget.occupied_tokens == expected

    assert {:ok, snap} = Loop.get_state(session)
    assert snap.tokens_used == expected

    # A message appended after the response (the next thing the user said)
    # moves both numbers by the same amount.
    extra = %{role: "user", content: String.duplicate("more context words ", 200)}
    :sys.replace_state(pid, fn s -> %{s | messages: s.messages ++ [extra]} end)

    grown = Telemetry.context_occupancy(:sys.get_state(pid))
    assert grown == @reported_input + Compactor.estimate_tokens(since ++ [extra])
    assert grown > expected

    assert {:ok, budget2} = SessionManager.context_budget(session)
    assert budget2.occupied_tokens == grown

    # The status-bar meter is fed by the context_pressure event.
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")
    Telemetry.emit_context_pressure(:sys.get_state(pid))

    assert_receive {:osa_event, %{type: :context_pressure, estimated_tokens: ^grown}}, 1_000
  end

  test "a history that shrank below the baseline adds nothing on top of the reported size" do
    state = %{
      last_input_tokens: 5_000,
      last_input_message_count: 50,
      messages: [%{role: "user", content: "hi"}]
    }

    assert Telemetry.context_occupancy(state) == 5_000
  end
end
