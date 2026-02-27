defmodule OptimalSystemAgent.Skills.Builtins.Orchestrate do
  @moduledoc """
  Orchestration skill — spawns multiple sub-agents to work on a complex task in parallel.

  Use this skill when a task benefits from decomposition: building entire applications,
  large refactors, multi-file changes, or any work that naturally splits into
  research/build/test/review phases.

  The skill delegates to the Agent.Orchestrator which handles:
  - Complexity analysis (decides if multi-agent is needed)
  - Sub-task decomposition via LLM
  - Dependency-aware parallel execution
  - Real-time progress tracking
  - Result synthesis
  """
  @behaviour OptimalSystemAgent.Skills.Behaviour

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

    # Read tools via persistent_term — we're inside Skills.Registry.handle_call,
    # so calling list_tools() would deadlock. list_tools_direct() is lock-free.
    tools = OptimalSystemAgent.Skills.Registry.list_tools_direct()

    Logger.info(
      "[Orchestrate Skill] Launching orchestration for task: #{String.slice(task, 0, 100)}"
    )

    try do
      case OptimalSystemAgent.Agent.Orchestrator.execute(task, session_id,
             strategy: strategy,
             cached_tools: tools
           ) do
        {:ok, _task_id, result} when is_binary(result) ->
          {:ok, result}

        {:ok, _task_id, nil} ->
          {:ok, "Orchestration completed but produced no synthesis result."}

        {:error, reason} ->
          {:error, "Orchestration failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[Orchestrate Skill] Exception: #{Exception.message(e)}")
        {:error, "Orchestration crashed: #{Exception.message(e)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: task"}
end
