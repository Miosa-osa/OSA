defmodule OptimalSystemAgent.Agent.ProgressTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Progress

  test "tracks single-agent lifecycle without a prior task-start event" do
    task_id = "task:progress:#{System.unique_integer([:positive])}"
    agent_id = "agent:progress:#{System.unique_integer([:positive])}"
    progress = Process.whereis(Progress)

    assert is_pid(progress)

    send(
      progress,
      {:orchestrator_event,
       %{
         event: :orchestrator_agent_started,
         task_id: task_id,
         agent_id: agent_id,
         agent_name: "builder",
         role: "builder"
       }}
    )

    send(
      progress,
      {:orchestrator_event,
       %{
         event: :orchestrator_agent_progress,
         task_id: task_id,
         agent_id: agent_id,
         tool_uses: 3,
         tokens_used: 1_500,
         current_action: "running tests"
       }}
    )

    send(
      progress,
      {:orchestrator_event,
       %{
         event: :orchestrator_agent_completed,
         task_id: task_id,
         agent_id: agent_id,
         status: :completed
       }}
    )

    assert {:ok, data} = eventually(fn -> Progress.get(task_id) end)
    assert data.status == :running

    [agent] = data.agents
    assert agent.id == agent_id
    assert agent.status == :completed
    assert agent.tool_uses == 3
    assert agent.tokens_used == 1_500
    assert agent.current_action == "running tests"
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, _} = ok ->
        ok

      _ ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: fun.()
end
