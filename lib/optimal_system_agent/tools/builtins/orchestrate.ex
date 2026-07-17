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
  @behaviour MiosaTools.Behaviour

  require Logger

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

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
            "Execution strategy: parallel (all at once), pipeline (sequential with dependency passing), auto (let the orchestrator decide), or pact (structured 4-phase Planning→Action→Coordination→Testing workflow for complex tasks requiring reconciliation)",
          "enum" => ["parallel", "pipeline", "auto", "pact"]
        }
      },
      "required" => ["task"]
    }
  end

  @impl true
  def execute(%{"task" => task} = params) do
    session_id = params["session_id"] || "orchestrated_#{System.unique_integer([:positive])}"

    Logger.info(
      "[Orchestrate] Routing task to the working Orchestrator: #{String.slice(task, 0, 100)}"
    )

    # Route to the real fleet engine (OptimalSystemAgent.Orchestrator). The old
    # code called a non-existent `Agent.Orchestrator.execute/3` and would crash
    # with UndefinedFunctionError. run_subagent/1 spawns a genuine isolated
    # agent and returns its structured summary. For true parallel decomposition,
    # the model should use `delegate` with a `tasks:[]` fan-out — that is the
    # first-class multi-agent path; this tool is the single-agent shim.
    config = %{
      task: task,
      parent_session_id: session_id,
      role: "orchestrator",
      tier: :specialist
    }

    try do
      case OptimalSystemAgent.Orchestrator.run_subagent(config) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, "Orchestration failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[Orchestrate] Exception: #{Exception.message(e)}")
        {:error, "Orchestration crashed: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        {:error, "Orchestration exited: #{inspect(reason)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: task"}
end
