defmodule OptimalSystemAgent.Agent.Orchestrator.SubagentStateIsKnowableTest do
  @moduledoc """
  "No recent signal" was a description of OUR ignorance, not of the subagent's
  state, and it came with no resolution: the user could not tell working-but-
  quiet from dead, and nothing guaranteed the state would ever change.

  Three properties are locked here, each corresponding to one way that could
  happen:

    1. **The silence is narrated.** Between dispatch and the first tool call the
       parent received exactly two events and then nothing — measured at 7.2s in
       the best case (mock provider, trivial task, temp dir) and minutes on a
       real repo with a real model. Every transition in that stretch now emits a
       phase, so a quiet agent is a described agent.

    2. **A queued agent exists.** Its RunStore row is created at DISPATCH rather
       than at admission, so `task_wait` / `task_output` / `task_stop` / the
       stall watcher can all see it. Previously `RunStore.get/1` answered `nil`
       for the entire queue wait and each of those read the `nil` as its own
       kind of "no".

    3. **Death is observed, not inferred.** The runner task is monitored, so a
       kill it cannot rescue from still produces a terminal event instead of a
       `START` with no `STOP`. This is the resolution guarantee, and it needs no
       timeout: `Process.monitor/1` fires immediately for an already-dead pid.
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
      Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)
      Application.delete_env(:optimal_system_agent, :max_fleet_agents)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    parent = "knowable-" <> Integer.to_string(System.unique_integer([:positive]))
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")
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

  # Drain phase frames off the subscribed topic for up to `budget` ms.
  defp collect_phases(acc \\ [], budget) do
    receive do
      {:osa_event, %{event: "background_agent_phase", phase: p}} ->
        collect_phases(acc ++ [p], budget)

      {:osa_event, %{type: :background_agent_completed}} ->
        acc

      {:osa_event, _} ->
        collect_phases(acc, budget)
    after
      budget -> acc
    end
  end

  test "the stretch before the first tool call is narrated, not silent", %{parent: parent} do
    Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 500)

    {:ok, _id} = Orchestrator.run_background(parent, config())

    phases = collect_phases(20_000)

    assert "starting" in phases,
           "the setup stretch must announce itself; got #{inspect(phases)}"

    assert "awaiting_model" in phases,
           "waiting on the model is the single most common reason a healthy " <>
             "subagent goes quiet for minutes — it must be named, not inferred " <>
             "from silence; got #{inspect(phases)}"
  end

  test "a queued agent is a run anyone can look up", %{parent: parent} do
    # A cap of zero means the very first agent queues. `live_agent_count/0`
    # excludes `:queued` rows, so this cannot be satisfied by the agent counting
    # itself out of its own queue.
    Application.put_env(:optimal_system_agent, :max_fleet_agents, 1)

    # Occupy the only slot with a row that is running and NOT queued.
    blocker = "knowable-blocker-" <> Integer.to_string(System.unique_integer([:positive]))

    RunStore.start_run(%{
      agent_id: blocker,
      parent_session_id: parent,
      role: "blocker",
      task: "hold the slot"
    })

    RunStore.set_phase(blocker, :working, "holding")

    {:ok, id} = Orchestrator.run_background(parent, config())

    # The row exists IMMEDIATELY — before admission, which is the whole point.
    run = RunStore.get(id)

    assert run != nil,
           "a queued agent must be visible to task_wait/task_output/task_stop; " <>
             "a nil row was read by each of them as 'no such run'"

    assert run.status == :running

    # And it does not count against the cap it is waiting behind, or the queue
    # would deadlock on itself.
    refute Orchestrator.live_agent_count() > 1,
           "queued rows must not consume the slots they are queued for"

    # Liveness is answerable, and never claims death for a run that is merely
    # waiting.
    {verdict, facts} = RunStore.liveness(id)
    assert verdict in [:alive, :unknown], "a queued agent is not dead: #{inspect(verdict)}"
    assert facts.phase == :queued

    RunStore.complete(blocker, %{agent_id: blocker, status: :completed, summary: "done"})
  end

  test "liveness distinguishes a live run from one whose owner is gone" do
    id = "knowable-live-" <> Integer.to_string(System.unique_integer([:positive]))

    RunStore.start_run(%{
      agent_id: id,
      parent_session_id: "p",
      role: "tester",
      task: "t"
    })

    # This process owns the lease it just claimed, so the run is demonstrably
    # alive — not "we heard from it recently", which is a different claim.
    assert {:alive, facts} = RunStore.liveness(id)
    assert is_integer(facts.silent_ms)

    RunStore.complete(id, %{agent_id: id, status: :completed, summary: "done"})
    assert {:finished, _} = RunStore.liveness(id)
  end

  test "a run whose runner dies without reporting is failed, not left running", %{parent: parent} do
    # The `try/rescue/catch` inside the runner covers faults raised INSIDE it and
    # nothing else. A kill delivered from outside used to leave a `START` with no
    # `STOP`: no terminal broadcast, a RunStore row stuck on `:running` until the
    # next boot, and a parent waiting on a result that could not come.
    id = "knowable-killed-" <> Integer.to_string(System.unique_integer([:positive]))

    RunStore.start_run(%{
      agent_id: id,
      parent_session_id: parent,
      role: "tester",
      task: "t"
    })

    victim = spawn(fn -> Process.sleep(:infinity) end)

    # Exercise the same watcher `run_background/2` installs.
    Orchestrator.watch_runner(parent, id, "tester", "tester", victim)

    Process.exit(victim, :kill)

    assert_receive {:osa_event, %{type: :background_agent_failed, agent_id: ^id}}, 5_000

    assert %{status: :failed} = RunStore.get(id),
           "the run must reach a terminal status without waiting for a timeout"
  end
end
