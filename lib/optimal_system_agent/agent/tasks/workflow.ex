defmodule OptimalSystemAgent.Agent.Tasks.Workflow do
  @moduledoc """
  Workflow decomposition and step tracking logic.

  Multi-step workflow awareness: decomposes tasks via LLM, tracks progress
  through sequential steps, and builds context blocks for prompt injection.
  Workflows persist to disk and survive restarts.

  Storage: ~/.osa/workflows/{workflow_id}.json
  """

  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Agent.Tasks.Persistence

  # ── Structs ────────────────────────────────────────────────────────────

  defstruct id: nil,
            name: nil,
            description: nil,
            status: :active,
            steps: [],
            current_step: 0,
            context: %{},
            created_at: nil,
            updated_at: nil,
            session_id: nil

  defmodule Step do
    @moduledoc "A single step within a workflow."
    defstruct id: nil,
              name: nil,
              description: nil,
              status: :pending,
              tools_needed: [],
              acceptance_criteria: nil,
              result: nil,
              started_at: nil,
              completed_at: nil
  end

  # ── Public: Workflow mutations ─────────────────────────────────────────

  @doc "Create a new workflow from a task description (LLM decomposition or template)."
  @spec create(map(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(state, task_description, session_id, opts \\ []) do
    case decompose_task(task_description, opts) do
      {:ok, steps} ->
        workflow = %__MODULE__{
          id: generate_id(),
          name: extract_name(task_description),
          description: task_description,
          status: :active,
          steps: steps,
          current_step: 0,
          context: %{},
          created_at: now_iso(),
          updated_at: now_iso(),
          session_id: session_id
        }

        workflow = mark_current_step_in_progress(workflow)
        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))

        Logger.info(
          "[Tasks.Workflow] Created #{workflow.id} (#{workflow.name}) — #{length(steps)} steps"
        )

        {:ok, {state, serialize(workflow)}}

      {:error, reason} ->
        Logger.warning("[Tasks.Workflow] Creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Advance workflow to next step."
  @spec advance(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def advance(state, workflow_id, result \\ nil) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status != :active ->
        {:error, {:invalid_status, status}}

      workflow ->
        workflow = complete_current_step(workflow, result)
        next_index = workflow.current_step + 1

        workflow =
          if next_index >= length(workflow.steps) do
            %{workflow | status: :completed, updated_at: now_iso()}
          else
            workflow = %{workflow | current_step: next_index, updated_at: now_iso()}
            mark_current_step_in_progress(workflow)
          end

        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))

        Logger.info(
          "[Tasks.Workflow] #{workflow_id}: step #{workflow.current_step + 1}/#{length(workflow.steps)} (#{workflow.status})"
        )

        {:ok, {state, serialize(workflow)}}
    end
  end

  @doc "Complete current step with a result (accumulates into context)."
  @spec complete_step(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def complete_step(state, workflow_id, result) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status != :active ->
        {:error, {:invalid_status, status}}

      workflow ->
        workflow = complete_current_step(workflow, result)
        current = Enum.at(workflow.steps, workflow.current_step)
        context_key = current.name |> String.downcase() |> String.replace(~r/\s+/, "_")

        workflow = %{
          workflow
          | context: Map.put(workflow.context, context_key, result),
            updated_at: now_iso()
        }

        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))
        {:ok, {state, serialize(workflow)}}
    end
  end

  @doc "Skip the current step."
  @spec skip_step(map(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def skip_step(state, workflow_id, reason \\ nil) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status != :active ->
        {:error, {:invalid_status, status}}

      workflow ->
        steps =
          List.update_at(workflow.steps, workflow.current_step, fn step ->
            %{step | status: :skipped, result: reason, completed_at: now_iso()}
          end)

        next_index = workflow.current_step + 1

        workflow =
          if next_index >= length(steps) do
            %{workflow | steps: steps, status: :completed, updated_at: now_iso()}
          else
            workflow = %{workflow | steps: steps, current_step: next_index, updated_at: now_iso()}
            mark_current_step_in_progress(workflow)
          end

        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))

        Logger.info("[Tasks.Workflow] #{workflow_id}: step #{workflow.current_step} skipped")
        {:ok, {state, serialize(workflow)}}
    end
  end

  @doc "Pause a workflow."
  @spec pause(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def pause(state, workflow_id) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      %{status: :active} = workflow ->
        workflow = %{workflow | status: :paused, updated_at: now_iso()}
        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))
        Logger.info("[Tasks.Workflow] #{workflow_id}: paused")
        {:ok, {state, serialize(workflow)}}

      %{status: status} ->
        {:error, {:invalid_status, status}}
    end
  end

  @doc "Resume a paused workflow."
  @spec resume(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(state, workflow_id) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      %{status: :paused} = workflow ->
        workflow = %{workflow | status: :active, updated_at: now_iso()}
        state = put_workflow(state, workflow)
        Persistence.save_workflow(state.dir, serialize(workflow))
        Logger.info("[Tasks.Workflow] #{workflow_id}: resumed")
        {:ok, {state, serialize(workflow)}}

      %{status: status} ->
        {:error, {:invalid_status, status}}
    end
  end

  # ── Public: Queries ────────────────────────────────────────────────────

  @doc "Get active workflow for a session."
  @spec active_workflow(map(), String.t()) :: map() | nil
  def active_workflow(state, session_id) do
    state.workflows
    |> Map.values()
    |> Enum.find(fn w -> w.session_id == session_id and w.status == :active end)
    |> case do
      nil -> nil
      workflow -> serialize(workflow)
    end
  end

  @doc "Get workflow status summary."
  @spec status(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(state, workflow_id) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:error, :not_found}

      workflow ->
        completed = Enum.count(workflow.steps, &(&1.status == :completed))
        skipped = Enum.count(workflow.steps, &(&1.status == :skipped))
        total = length(workflow.steps)
        current = Enum.at(workflow.steps, workflow.current_step)

        {:ok,
         %{
           id: workflow.id,
           name: workflow.name,
           status: workflow.status,
           progress: "#{completed}/#{total}",
           completed_steps: completed,
           skipped_steps: skipped,
           total_steps: total,
           current_step:
             if(current, do: %{name: current.name, status: current.status}, else: nil),
           created_at: workflow.created_at,
           updated_at: workflow.updated_at
         }}
    end
  end

  @doc "List workflows for a session."
  @spec list(map(), String.t()) :: [map()]
  def list(state, session_id) do
    state.workflows
    |> Map.values()
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.map(fn w ->
      completed = Enum.count(w.steps, &(&1.status == :completed))

      %{
        id: w.id,
        name: w.name,
        status: w.status,
        progress: "#{completed}/#{length(w.steps)}",
        created_at: w.created_at
      }
    end)
  end

  @doc "Build a context block string for prompt injection."
  @spec context_block(map(), String.t()) :: String.t() | nil
  def context_block(state, session_id) do
    active =
      state.workflows
      |> Map.values()
      |> Enum.find(fn w -> w.session_id == session_id and w.status == :active end)

    if active, do: build_context_block(active), else: nil
  end

  @doc "Auto-detect if a message implies a workflow should be created."
  @spec should_create?(String.t()) :: boolean()
  def should_create?(message) when is_binary(message) do
    has_multi_step =
      Regex.match?(
        ~r/\b(build|create|develop|implement|set up|design|architect|scaffold|deploy)\b.*\b(app|application|api|system|project|website|service|platform|pipeline|database|backend|frontend)\b/i,
        message
      )

    has_workflow_language =
      Regex.match?(
        ~r/\b(step by step|from scratch|end to end|full|complete|entire|comprehensive|walkthrough|guide me through)\b/i,
        message
      )

    is_long = String.length(message) > 100

    has_phase_language =
      Regex.match?(
        ~r/\b(plan|phase|milestone|roadmap|sprint|breakdown|decompose|stages?|steps?)\b/i,
        message
      ) and is_long

    has_multi_step or (has_workflow_language and is_long) or has_phase_language
  end

  def should_create?(_), do: false

  # ── Initialization ─────────────────────────────────────────────────────

  @doc "Load workflows from disk into a new state map."
  @spec init_state() :: map()
  def init_state do
    dir = Persistence.workflows_dir()
    File.mkdir_p!(dir)

    workflows =
      dir
      |> Persistence.load_all_workflows()
      |> Enum.reduce(%{}, fn data, acc ->
        workflow = deserialize(data)
        Map.put(acc, workflow.id, workflow)
      end)

    Logger.info("[Tasks.Workflow] #{map_size(workflows)} workflow(s) loaded from #{dir}")
    %{workflows: workflows, dir: dir}
  end

  # ── Serialization ──────────────────────────────────────────────────────

  @doc false
  def serialize(workflow) do
    %{
      "id" => workflow.id,
      "name" => workflow.name,
      "description" => workflow.description,
      "status" => to_string(workflow.status),
      "current_step" => workflow.current_step,
      "context" => workflow.context || %{},
      "created_at" => workflow.created_at,
      "updated_at" => workflow.updated_at,
      "session_id" => workflow.session_id,
      "steps" => Enum.map(workflow.steps, &serialize_step/1)
    }
  end

  @doc false
  def deserialize(data) when is_map(data) do
    steps = (data["steps"] || []) |> Enum.map(&deserialize_step/1)

    %__MODULE__{
      id: data["id"],
      name: data["name"],
      description: data["description"],
      status: parse_status(data["status"]),
      steps: steps,
      current_step: data["current_step"] || 0,
      context: data["context"] || %{},
      created_at: data["created_at"],
      updated_at: data["updated_at"],
      session_id: data["session_id"]
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp decompose_task(description, opts) do
    case Keyword.get(opts, :template) do
      nil -> decompose_via_llm(description)
      template_path when is_binary(template_path) -> load_template(template_path)
    end
  end

  defp decompose_via_llm(description) do
    prompt = """
    You are a project planner. Decompose this task into clear, sequential steps.
    Respond ONLY with a JSON array. Each step has: name, description, tools_needed, acceptance_criteria.

    tools_needed is a list of: shell_execute, file_read, file_write, web_search, memory_save

    Keep it practical — between 3 and 12 steps. Each step should be completable in one focused session.

    Task: "#{String.slice(description, 0, 500)}"

    Respond with ONLY the JSON array, no markdown fences:
    [{"name": "...", "description": "...", "tools_needed": ["file_write"], "acceptance_criteria": "..."}]
    """

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.3, max_tokens: 2048) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_steps_response(content)

      {:ok, _} ->
        {:error, "LLM returned empty response for task decomposition"}

      {:error, reason} ->
        {:error, "LLM call failed during task decomposition: #{inspect(reason)}"}
    end
  end

  defp parse_steps_response(content) do
    cleaned =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, steps} when is_list(steps) and length(steps) > 0 ->
        parsed =
          steps
          |> Enum.with_index()
          |> Enum.map(fn {step_data, index} ->
            %Step{
              id: "step_#{index + 1}",
              name: Map.get(step_data, "name", "Step #{index + 1}"),
              description: Map.get(step_data, "description", ""),
              status: :pending,
              tools_needed: Map.get(step_data, "tools_needed", []),
              acceptance_criteria: Map.get(step_data, "acceptance_criteria")
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:error, "LLM returned invalid steps format (expected non-empty array)"}

      {:error, reason} ->
        Logger.warning(
          "[Tasks.Workflow] Failed to parse LLM step response: #{inspect(reason)}\nRaw: #{String.slice(cleaned, 0, 200)}"
        )

        {:error, "Failed to parse LLM decomposition response as JSON"}
    end
  end

  defp load_template(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      case with {:ok, raw} <- File.read(expanded),
                {:ok, decoded} <- Jason.decode(raw),
                do: {:ok, decoded} do
        {:ok, %{"steps" => steps}} when is_list(steps) ->
          parsed =
            steps
            |> Enum.with_index()
            |> Enum.map(fn {step_data, index} ->
              %Step{
                id: "step_#{index + 1}",
                name: Map.get(step_data, "name", "Step #{index + 1}"),
                description: Map.get(step_data, "description", ""),
                status: :pending,
                tools_needed: Map.get(step_data, "tools_needed", []),
                acceptance_criteria: Map.get(step_data, "acceptance_criteria")
              }
            end)

          {:ok, parsed}

        {:error, reason} ->
          {:error, "Failed to parse template: #{inspect(reason)}"}

        _ ->
          {:error, "Template must contain a 'steps' array"}
      end
    else
      {:error, "Template not found: #{expanded}"}
    end
  rescue
    e -> {:error, "Error loading template: #{Exception.message(e)}"}
  end

  defp build_context_block(workflow) do
    completed = Enum.count(workflow.steps, &(&1.status == :completed))
    skipped = Enum.count(workflow.steps, &(&1.status == :skipped))
    total = length(workflow.steps)
    current = Enum.at(workflow.steps, workflow.current_step)

    if current == nil do
      nil
    else
      """
      ## Active Workflow: #{workflow.name}
      Progress: #{completed}/#{total} steps completed#{if skipped > 0, do: " (#{skipped} skipped)", else: ""}

      ### Current Step: #{current.name}
      #{current.description}
      Tools available: #{Enum.join(current.tools_needed || [], ", ")}
      #{if current.acceptance_criteria, do: "Acceptance criteria: #{current.acceptance_criteria}", else: ""}

      ### Completed Steps
      #{format_completed_steps(workflow)}

      ### Remaining Steps
      #{format_remaining_steps(workflow)}

      ### Accumulated Context
      #{format_context(workflow.context)}

      Focus on completing the current step. When done, report what was accomplished
      so the workflow can advance to the next step.
      """
    end
  end

  defp format_completed_steps(workflow) do
    workflow.steps
    |> Enum.filter(&(&1.status in [:completed, :skipped]))
    |> case do
      [] ->
        "None yet."

      steps ->
        Enum.map_join(steps, "\n", fn step ->
          status_icon = if step.status == :completed, do: "[done]", else: "[skipped]"

          result_text =
            if step.result, do: " - #{truncate(to_string(step.result), 120)}", else: ""

          "- #{status_icon} #{step.name}#{result_text}"
        end)
    end
  end

  defp format_remaining_steps(workflow) do
    workflow.steps
    |> Enum.drop(workflow.current_step + 1)
    |> Enum.filter(&(&1.status == :pending))
    |> case do
      [] ->
        "None — this is the last step."

      steps ->
        Enum.map_join(steps, "\n", fn step ->
          "- #{step.name}: #{truncate(step.description || "", 80)}"
        end)
    end
  end

  defp format_context(context) when map_size(context) == 0, do: "No accumulated context yet."

  defp format_context(context) do
    Enum.map_join(context, "\n", fn {key, value} ->
      "- **#{key}**: #{truncate(to_string(value), 150)}"
    end)
  end

  defp put_workflow(state, workflow) do
    %{state | workflows: Map.put(state.workflows, workflow.id, workflow)}
  end

  defp mark_current_step_in_progress(workflow) do
    steps =
      List.update_at(workflow.steps, workflow.current_step, fn step ->
        %{step | status: :in_progress, started_at: now_iso()}
      end)

    %{workflow | steps: steps}
  end

  defp complete_current_step(workflow, result) do
    steps =
      List.update_at(workflow.steps, workflow.current_step, fn step ->
        %{step | status: :completed, result: result, completed_at: now_iso()}
      end)

    %{workflow | steps: steps}
  end

  defp serialize_step(step) do
    %{
      "id" => step.id,
      "name" => step.name,
      "description" => step.description,
      "status" => to_string(step.status),
      "tools_needed" => step.tools_needed || [],
      "acceptance_criteria" => step.acceptance_criteria,
      "result" => step.result,
      "started_at" => step.started_at,
      "completed_at" => step.completed_at
    }
  end

  defp deserialize_step(data) when is_map(data) do
    %Step{
      id: data["id"],
      name: data["name"],
      description: data["description"],
      status: parse_status(data["status"]),
      tools_needed: data["tools_needed"] || [],
      acceptance_criteria: data["acceptance_criteria"],
      result: data["result"],
      started_at: data["started_at"],
      completed_at: data["completed_at"]
    }
  end

  defp generate_id, do: OptimalSystemAgent.Utils.ID.generate("wf")
  defp now_iso, do: OptimalSystemAgent.Utils.Text.now_iso()
  defp truncate(str, max_len), do: OptimalSystemAgent.Utils.Text.truncate(str, max_len)

  defp extract_name(description) do
    description
    |> String.split(~r/[.!?\n]/, parts: 2)
    |> List.first()
    |> String.trim()
    |> truncate(60)
  end

  defp parse_status(nil), do: :pending
  defp parse_status("active"), do: :active
  defp parse_status("paused"), do: :paused
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("skipped"), do: :skipped
  defp parse_status(atom) when is_atom(atom), do: atom
  defp parse_status(_), do: :pending
end
