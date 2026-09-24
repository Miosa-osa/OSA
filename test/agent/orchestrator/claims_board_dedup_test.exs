defmodule OptimalSystemAgent.Agent.Orchestrator.ClaimsBoardDedupTest do
  @moduledoc """
  VSM item 7 — the claims board's automatic, advisory task-dedup check on
  real subagent dispatch: two `Orchestrator.run_subagent/1` calls with
  overlapping tasks. The SECOND dispatch is not blocked (advisory-only at
  this integration point — see `Orchestrator.register_task_claim/4`'s
  moduledoc note), but a `:claims_board_conflict` event is surfaced, and the
  active claim is visible on the board while both agents are in flight.

  MockProvider-driven — real `Orchestrator.run_subagent/1` calls, real
  `Loop` GenServers, no LLM/network dependency.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.FileLocking.ClaimsBoard, as: Board
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()
    MockProvider.queue_final_texts(["done"])

    on_exit(fn ->
      MockProvider.reset_final_texts()

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    :ok
  end

  defp uniq(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp config(subagent_id, parent_id, task) do
    %{
      task: task,
      parent_session_id: parent_id,
      agent_id: subagent_id,
      role: "tester",
      tier: :specialist,
      model: "mock-model-1.0",
      provider: :mock,
      working_dir: System.tmp_dir!()
    }
  end

  defp capture_claims_conflict_events(session_id) do
    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        data =
          case payload do
            %{data: d} when is_map(d) -> d
            d when is_map(d) -> d
          end

        if data[:event] == :claims_board_conflict and data[:session_id] == session_id do
          send(test_pid, {:claims_conflict, data})
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
    ref
  end

  test "the second of two near-duplicate task dispatches surfaces a claims-board conflict" do
    parent_id = uniq("dedup-parent")
    first_id = uniq("dedup-agent-first")
    second_id = uniq("dedup-agent-second")

    capture_claims_conflict_events(parent_id)

    task_text = "investigate why the checkout flow times out under load"

    # First dispatch: no conflict yet, and it registers a claim.
    {:ok, _} = Orchestrator.run_subagent(config(first_id, parent_id, task_text))

    assert Enum.any?(
             Board.active_claims(),
             &(&1.kind == :task and String.contains?(&1.target, "checkout flow"))
           ),
           "the first dispatch's task must be visible on the board while it is (or was, before " <>
             "liveness sweep) in flight"

    # Second dispatch, moments later, with an overlapping description: NOT
    # blocked (advisory at this automatic integration point) but surfaced.
    {:ok, _} =
      Orchestrator.run_subagent(
        config(second_id, parent_id, "look into the checkout flow timing out under heavy load")
      )

    assert_receive {:claims_conflict, %{kind: :task, agent_id: ^second_id}}, 2_000
  end

  test "two dispatches with UNRELATED tasks never surface a conflict" do
    parent_id = uniq("dedup-parent")
    first_id = uniq("dedup-unrelated-first")
    second_id = uniq("dedup-unrelated-second")

    capture_claims_conflict_events(parent_id)

    {:ok, _} =
      Orchestrator.run_subagent(config(first_id, parent_id, "investigate the checkout timeout"))

    {:ok, _} =
      Orchestrator.run_subagent(config(second_id, parent_id, "write the Q3 release notes"))

    refute_receive {:claims_conflict, %{agent_id: ^second_id}}, 300
  end
end
