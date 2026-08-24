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
        },
        "priority" => %{
          "type" => "string",
          "description" =>
            "Speed/cost priority biasing model tier + provider order for every spawned agent: immediate (fastest/highest tier), standard (default), loose (cheapest/most latency-tolerant).",
          "enum" => ["immediate", "standard", "loose"]
        }
      },
      "required" => ["task"]
    }
  end

  @impl true
  def execute(%{"task" => task} = params) do
    session_id = params["session_id"] || "orchestrated_#{System.unique_integer([:positive])}"
    # Honest schema: the advertised strategy now actually drives execution via
    # Swarm.Patterns.dispatch (parallel/pipeline/debate/review_loop/pact/auto).
    # nil strategy defaults to :auto (heuristic single-vs-pipeline decision).
    strategy = params["strategy"] || "auto"

    # The caller's own delegation depth, injected by the agent loop's
    # ToolExecutor. Threaded into every spawned config so `run_subagent`
    # increments from the TRUE nesting level — without it, orchestrate-spawned
    # children always started at depth 1, so a subagent that called orchestrate
    # again reset the counter and the fork-bomb ceiling was never reached.
    depth = params["__delegation_depth__"] || 0

    # Speed/cost priority (immediate|standard|loose). Threaded into every spawned
    # config so DelegationRouter biases model tier + provider order the same way
    # the `delegate` path already does — swarm agents previously never got the
    # cost benefit because this path never passed priority through. Defaults to
    # :standard when the caller omits it.
    priority = params["priority"] || "standard"

    Logger.info(
      "[Orchestrate] strategy=#{strategy} priority=#{priority} depth=#{depth} task=#{String.slice(task, 0, 100)}"
    )

    try do
      case OptimalSystemAgent.Swarm.Patterns.dispatch(strategy, session_id, task,
             depth: depth,
             priority: priority
           ) do
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
