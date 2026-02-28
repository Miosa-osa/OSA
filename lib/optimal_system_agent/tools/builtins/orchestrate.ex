defmodule OptimalSystemAgent.Tools.Builtins.Orchestrate do
  @moduledoc """
  Orchestration tool — spawns multiple sub-agents to work on a complex task in parallel.

  Use this tool when a task benefits from decomposition: building entire applications,
  large refactors, multi-file changes, or any work that naturally splits into
  research/build/test/review phases.

  The tool delegates to the Agent.Orchestrator which handles:
  - Complexity analysis (decides if multi-agent is needed)
  - Sub-task decomposition via LLM
  - Dependency-aware parallel execution
  - Real-time progress tracking
  - Result synthesis
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @impl true
  def name, do: "orchestrate"

  @impl true
  def description do
    "Spawn multiple sub-agents to work on a complex task in parallel. " <>
      "Use this for tasks that benefit from decomposition (building apps, large refactors, multi-file changes)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "The complex task to decompose and execute with multiple agents"
        },
        "strategy" => %{
          "type" => "string",
          "description" =>
            "Execution strategy: parallel (all at once), pipeline (sequential with dependency passing), or auto (let the orchestrator decide)",
          "enum" => ["parallel", "pipeline", "auto"]
        }
      },
      "required" => ["task"]
    }
  end

  @impl true
  def execute(%{"task" => task} = params) do
    strategy = params["strategy"] || "auto"
    session_id = params["session_id"] || "orchestrated_#{System.unique_integer([:positive])}"

    # Read tools via persistent_term — we're inside Tools.Registry.handle_call,
    # so calling list_tools() would deadlock. list_tools_direct() is lock-free.
    tools = OptimalSystemAgent.Tools.Registry.list_tools_direct()

    Logger.info(
      "[Orchestrate Skill] Launching orchestration for task: #{String.slice(task, 0, 100)}"
    )

    caller = self()
    ref = make_ref()

    # Register handler BEFORE calling execute to close the race window where
    # the orchestrator could complete and emit its event before we start
    # listening. Handler sends all orchestration events to our mailbox;
    # await_result/3 filters by task_id once we know it.
    handler_ref =
      OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
        event = Map.get(payload, :event)

        if event == :orchestrator_task_completed or event == :orchestrator_task_failed do
          send(caller, {:orch_event, ref, event, Map.get(payload, :task_id), Map.get(payload, :reason)})
        end
      end)

    try do
      result =
        case OptimalSystemAgent.Agent.Orchestrator.execute(task, session_id,
               strategy: strategy,
               cached_tools: tools
             ) do
          {:ok, task_id} ->
            case await_result(task_id, ref, 300_000) do
              {:ok, synthesis} -> {:ok, synthesis}
              {:error, :timeout} -> {:error, "Orchestration timed out after 300s (task: #{task_id})"}
            end

          {:error, reason} ->
            {:error, "Orchestration failed: #{inspect(reason)}"}
        end

      OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, handler_ref)
      result
    rescue
      e ->
        OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, handler_ref)
        Logger.error("[Orchestrate Skill] Exception: #{Exception.message(e)}")
        {:error, "Orchestration crashed: #{Exception.message(e)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: task"}

  # Wait for the orchestration result with a monotonic deadline.
  # Uses a deadline (not rolling timeout) so re-dispatched events for other
  # tasks don't silently extend the wait window.
  defp await_result(task_id, ref, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_result(task_id, ref, deadline)
  end

  defp do_await_result(task_id, ref, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:orch_event, ^ref, :orchestrator_task_completed, ^task_id, _reason} ->
          case OptimalSystemAgent.Agent.Orchestrator.progress(task_id) do
            {:ok, %{synthesis: s}} when is_binary(s) and s != "" -> {:ok, s}
            {:ok, %{status: :completed}} -> {:ok, "Orchestration completed."}
            _ -> {:ok, "Orchestration completed."}
          end

        {:orch_event, ^ref, :orchestrator_task_failed, ^task_id, reason} ->
          {:error, "Orchestration failed: #{inspect(reason)}"}

        {:orch_event, ^ref, _event, _other_task_id, _reason} ->
          # Event for a different task — discard and keep waiting, preserving deadline
          do_await_result(task_id, ref, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end
end
