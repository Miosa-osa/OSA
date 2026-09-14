defmodule OptimalSystemAgent.Agent.Orchestrator.RunBackgroundMarksRowBackgroundTest do
  @moduledoc """
  `Orchestrator.run_background/2` — the entry point for `delegate(background:
  true)` and the resume/retry paths that reuse it — must leave its RunStore row
  marked `background: true` from the moment it registers (synchronously, at
  dispatch, before admission), and that marker must survive `run_subagent/1`'s
  own later `RunStore.start_run/1` call once the Task actually runs (which
  otherwise replaces the row wholesale). This is the field `Loop.cancel/1`'s
  `descendant_session_ids/1` reads to exclude a background run from an
  interrupt's cascade.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :max_fleet_agents)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    parent = "runbg-mark-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, parent: parent}
  end

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        task: "say hello",
        role: "tester",
        tier: :specialist,
        model: "mock-model-1.0",
        provider: :mock,
        working_dir: System.tmp_dir!()
      },
      overrides
    )
  end

  test "the row is marked background: true at dispatch, before the Task even runs",
       %{parent: parent} do
    Application.put_env(
      :optimal_system_agent,
      :max_fleet_agents,
      Orchestrator.live_agent_count() + 2
    )

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

    {:ok, id} = Orchestrator.run_background(parent, config())

    # Synchronous: `run_background/2` registers this row and returns before
    # its Task is even scheduled to run — no waiting required for THIS
    # assertion, but the test still waits for the Task to finish below so it
    # does not leave a live background Task running past the test itself.
    assert %{background: true, status: :running} = RunStore.get(id)

    assert_receive {:osa_event, %{type: :background_agent_completed, agent_id: ^id}}, 20_000
  end

  test "the marker survives run_subagent/1's own start_run call once the Task runs",
       %{parent: parent} do
    Application.put_env(
      :optimal_system_agent,
      :max_fleet_agents,
      Orchestrator.live_agent_count() + 2
    )

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

    {:ok, id} = Orchestrator.run_background(parent, config())

    assert_receive {:osa_event, %{type: :background_agent_completed, agent_id: ^id}}, 20_000

    # `run_subagent/1` (called inside the Task) does its OWN `RunStore.start_run/1`
    # — "start or REPLACE" — once admitted. If `:background_dispatch` were not
    # threaded through, this second write would have silently reset the row to
    # the `false` default.
    assert %{background: true, status: :completed} = RunStore.get(id)
  end

  test "a plain foreground dispatch is NOT marked background", %{parent: parent} do
    {:ok, result} = Orchestrator.run_subagent(config(%{parent_session_id: parent}))
    assert is_binary(result)

    # The foreground path generates its own agent_id; find it via RunStore's
    # parent-child index rather than threading it back out of run_subagent/1.
    [run] = Enum.filter(RunStore.list(limit: 100), &(&1.parent_session_id == parent))
    assert run.background == false
  end
end
