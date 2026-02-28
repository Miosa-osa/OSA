defmodule OptimalSystemAgent.Agent.Workflow do
  @moduledoc """
  Workflow tracking — multi-step task awareness.

  When a user starts a complex task, OSA decomposes it into steps,
  tracks progress, and maintains context across conversation turns.
  This enables OSA to build entire applications, manage projects,
  and handle any multi-step workflow that would normally require
  constant human guidance.

  Workflows persist to disk so they survive restarts.
  Active workflow context is injected into the agent prompt.

  Storage: ~/.osa/workflows/{workflow_id}.json
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  # ── Structs ──────────────────────────────────────────────────────────

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
              signal_mode: nil,
              tools_needed: [],
              acceptance_criteria: nil,
              result: nil,
              started_at: nil,
              completed_at: nil
  end

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Start a new workflow from a task description (uses LLM to decompose)."
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(task_description, session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create, task_description, session_id, opts}, 60_000)
  end

  @doc "Get the active workflow for a session."
  @spec active_workflow(String.t()) :: map() | nil
  def active_workflow(session_id) do
    GenServer.call(__MODULE__, {:active_workflow, session_id})
  end

  @doc "Advance to the next step (called when current step is completed)."
  @spec advance(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def advance(workflow_id, result \\ nil) do
    GenServer.call(__MODULE__, {:advance, workflow_id, result})
  end

  @doc "Mark current step as completed with a result."
  @spec complete_step(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def complete_step(workflow_id, result) do
    GenServer.call(__MODULE__, {:complete_step, workflow_id, result})
  end

  @doc "Skip a step."
  @spec skip_step(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def skip_step(workflow_id, reason \\ nil) do
    GenServer.call(__MODULE__, {:skip_step, workflow_id, reason})
  end

  @doc "Pause a workflow."
  @spec pause(String.t()) :: {:ok, map()} | {:error, term()}
  def pause(workflow_id) do
    GenServer.call(__MODULE__, {:pause, workflow_id})
  end

  @doc "Resume a paused workflow."
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(workflow_id) do
    GenServer.call(__MODULE__, {:resume, workflow_id})
  end

  @doc "Get workflow status and progress."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(workflow_id) do
    GenServer.call(__MODULE__, {:status, workflow_id})
  end

  @doc "List all workflows for a session."
  @spec list(String.t()) :: [map()]
  def list(session_id) do
    GenServer.call(__MODULE__, {:list, session_id})
  end

  @doc "Get context string for injection into agent prompt."
  @spec context_block(String.t()) :: String.t() | nil
  def context_block(session_id) do
    GenServer.call(__MODULE__, {:context_block, session_id})
  end

  @doc "Auto-detect if a message implies a workflow should be created."
  @spec should_create_workflow?(String.t()) :: boolean()
  def should_create_workflow?(message) when is_binary(message) do
    # Multi-step indicators: building/creating something substantial
    has_multi_step =
      Regex.match?(
        ~r/\b(build|create|develop|implement|set up|design|architect|scaffold|deploy)\b.*\b(app|application|api|system|project|website|service|platform|pipeline|database|backend|frontend)\b/i,
        message
      )

    # Explicit workflow language
    has_workflow_language =
      Regex.match?(
        ~r/\b(step by step|from scratch|end to end|full|complete|entire|comprehensive|walkthrough|guide me through)\b/i,
        message
      )

    # Length indicator (complex requests tend to be longer)
    is_long = String.length(message) > 100

    # Multi-phase language
    has_phase_language =
      Regex.match?(
        ~r/\b(plan|phase|milestone|roadmap|sprint|breakdown|decompose|stages?|steps?)\b/i,
        message
      ) and is_long

    has_multi_step or (has_workflow_language and is_long) or has_phase_language
  end

  def should_create_workflow?(_), do: false

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(:ok) do
    dir = workflows_dir()
    File.mkdir_p!(dir)

    workflows = load_all_workflows(dir)
    Logger.info("Workflow engine started — #{map_size(workflows)} workflow(s) loaded from #{dir}")

    {:ok, %{workflows: workflows, dir: dir}}
  end

  @impl true
  def handle_call({:create, task_description, session_id, opts}, _from, state) do
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
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          session_id: session_id
        }

        # Mark the first step as in_progress
        workflow = mark_current_step_in_progress(workflow)

        state = put_workflow(state, workflow)
        persist_workflow(state.dir, workflow)

        Logger.info(
          "Workflow created: #{workflow.id} (#{workflow.name}) — #{length(steps)} steps"
        )

        {:reply, {:ok, serialize_workflow(workflow)}, state}

      {:error, reason} ->
        Logger.warning("Workflow creation failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:active_workflow, session_id}, _from, state) do
    active =
      state.workflows
      |> Map.values()
      |> Enum.find(fn w -> w.session_id == session_id and w.status == :active end)

    result = if active, do: serialize_workflow(active), else: nil
    {:reply, result, state}
  end

  @impl true
  def handle_call({:advance, workflow_id, result}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status != :active ->
        {:reply, {:error, {:invalid_status, status}}, state}

      workflow ->
        # Complete current step with result
        workflow = complete_current_step(workflow, result)

        # Advance to the next step
        next_index = workflow.current_step + 1

        workflow =
          if next_index >= length(workflow.steps) do
            # All steps done
            %{workflow | status: :completed, updated_at: now_iso()}
          else
            workflow = %{workflow | current_step: next_index, updated_at: now_iso()}
            mark_current_step_in_progress(workflow)
          end

        state = put_workflow(state, workflow)
        persist_workflow(state.dir, workflow)

        Logger.info(
          "Workflow #{workflow_id}: advanced to step #{workflow.current_step + 1}/#{length(workflow.steps)} (status: #{workflow.status})"
        )

        {:reply, {:ok, serialize_workflow(workflow)}, state}
    end
  end

  @impl true
  def handle_call({:complete_step, workflow_id, result}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status != :active ->
        {:reply, {:error, {:invalid_status, status}}, state}

      workflow ->
        workflow = complete_current_step(workflow, result)

        # Accumulate result into context
        current = Enum.at(workflow.steps, workflow.current_step)
        context_key = current.name |> String.downcase() |> String.replace(~r/\s+/, "_")

        workflow = %{
          workflow
          | context: Map.put(workflow.context, context_key, result),
            updated_at: now_iso()
        }

        state = put_workflow(state, workflow)
        persist_workflow(state.dir, workflow)

        {:reply, {:ok, serialize_workflow(workflow)}, state}
    end
  end

  @impl true
  def handle_call({:skip_step, workflow_id, reason}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status != :active ->
        {:reply, {:error, {:invalid_status, status}}, state}

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
        persist_workflow(state.dir, workflow)

        Logger.info("Workflow #{workflow_id}: step #{workflow.current_step} skipped")

        {:reply, {:ok, serialize_workflow(workflow)}, state}
    end
  end

  @impl true
  def handle_call({:pause, workflow_id}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :active} = workflow ->
        workflow = %{workflow | status: :paused, updated_at: now_iso()}
        state = put_workflow(state, workflow)
        persist_workflow(state.dir, workflow)
        Logger.info("Workflow #{workflow_id}: paused")
        {:reply, {:ok, serialize_workflow(workflow)}, state}

      %{status: status} ->
        {:reply, {:error, {:invalid_status, status}}, state}
    end
  end

  @impl true
  def handle_call({:resume, workflow_id}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :paused} = workflow ->
        workflow = %{workflow | status: :active, updated_at: now_iso()}
        state = put_workflow(state, workflow)
        persist_workflow(state.dir, workflow)
        Logger.info("Workflow #{workflow_id}: resumed")
        {:reply, {:ok, serialize_workflow(workflow)}, state}

      %{status: status} ->
        {:reply, {:error, {:invalid_status, status}}, state}
    end
  end

  @impl true
  def handle_call({:status, workflow_id}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workflow ->
        completed = Enum.count(workflow.steps, &(&1.status == :completed))
        skipped = Enum.count(workflow.steps, &(&1.status == :skipped))
        total = length(workflow.steps)
        current = Enum.at(workflow.steps, workflow.current_step)

        result = %{
          id: workflow.id,
          name: workflow.name,
          status: workflow.status,
          progress: "#{completed}/#{total}",
          completed_steps: completed,
          skipped_steps: skipped,
          total_steps: total,
          current_step: if(current, do: %{name: current.name, status: current.status}, else: nil),
          created_at: workflow.created_at,
          updated_at: workflow.updated_at
        }

        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call({:list, session_id}, _from, state) do
    workflows =
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

    {:reply, workflows, state}
  end

  @impl true
  def handle_call({:context_block, session_id}, _from, state) do
    active =
      state.workflows
      |> Map.values()
      |> Enum.find(fn w -> w.session_id == session_id and w.status == :active end)

    result =
      case active do
        nil ->
          nil

        workflow ->
          build_context_block(workflow)
      end

    {:reply, result, state}
  end

  # ── LLM Task Decomposition ──────────────────────────────────────────

  defp decompose_task(description, opts) do
    # Check if a template was provided
    case Keyword.get(opts, :template) do
      nil ->
        decompose_via_llm(description)

      template_path when is_binary(template_path) ->
        load_template(template_path)
    end
  end

  defp decompose_via_llm(description) do
    prompt = """
    You are a project planner. Decompose this task into clear, sequential steps.
    Respond ONLY with a JSON array. Each step has: name, description, signal_mode, tools_needed, acceptance_criteria.

    signal_mode is one of: BUILD, EXECUTE, ANALYZE, ASSIST, MAINTAIN
    tools_needed is a list of: shell_execute, file_read, file_write, web_search, memory_save

    Keep it practical — between 3 and 12 steps. Each step should be completable in one focused session.

    Task: "#{String.slice(description, 0, 500)}"

    Respond with ONLY the JSON array, no markdown fences:
    [{"name": "...", "description": "...", "signal_mode": "BUILD", "tools_needed": ["file_write"], "acceptance_criteria": "..."}]
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
    # Strip markdown code fences if present
    cleaned =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, steps} when is_list(steps) and length(steps) > 0 ->
        parsed_steps =
          steps
          |> Enum.with_index()
          |> Enum.map(fn {step_data, index} ->
            %Step{
              id: "step_#{index + 1}",
              name: Map.get(step_data, "name", "Step #{index + 1}"),
              description: Map.get(step_data, "description", ""),
              status: :pending,
              signal_mode: parse_signal_mode(Map.get(step_data, "signal_mode", "BUILD")),
              tools_needed: Map.get(step_data, "tools_needed", []),
              acceptance_criteria: Map.get(step_data, "acceptance_criteria")
            }
          end)

        {:ok, parsed_steps}

      {:ok, _} ->
        {:error, "LLM returned invalid steps format (expected non-empty array)"}

      {:error, reason} ->
        Logger.warning(
          "Failed to parse LLM step response: #{inspect(reason)}\nRaw: #{String.slice(cleaned, 0, 200)}"
        )

        {:error, "Failed to parse LLM decomposition response as JSON"}
    end
  end

  defp load_template(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      case File.read(expanded) |> then(fn {:ok, raw} -> Jason.decode(raw) end) do
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
                signal_mode: parse_signal_mode(Map.get(step_data, "signal_mode", "BUILD")),
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

  # ── Context Block Builder ────────────────────────────────────────────

  defp build_context_block(workflow) do
    completed = Enum.count(workflow.steps, &(&1.status == :completed))
    skipped = Enum.count(workflow.steps, &(&1.status == :skipped))
    total = length(workflow.steps)
    current = Enum.at(workflow.steps, workflow.current_step)

    if current == nil do
      nil
    else
      completed_section = format_completed_steps(workflow)
      remaining_section = format_remaining_steps(workflow)
      context_section = format_context(workflow.context)

      """
      ## Active Workflow: #{workflow.name}
      Progress: #{completed}/#{total} steps completed#{if skipped > 0, do: " (#{skipped} skipped)", else: ""}

      ### Current Step: #{current.name}
      #{current.description}
      Expected mode: #{current.signal_mode || "BUILD"}
      Tools available: #{Enum.join(current.tools_needed || [], ", ")}
      #{if current.acceptance_criteria, do: "Acceptance criteria: #{current.acceptance_criteria}", else: ""}

      ### Completed Steps
      #{completed_section}

      ### Remaining Steps
      #{remaining_section}

      ### Accumulated Context
      #{context_section}

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

  # ── Persistence ──────────────────────────────────────────────────────

  defp persist_workflow(dir, workflow) do
    path = Path.join(dir, "#{workflow.id}.json")
    data = serialize_workflow(workflow)

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.error("Failed to persist workflow #{workflow.id}: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("Failed to persist workflow #{workflow.id}: #{Exception.message(e)}")
  end

  defp load_all_workflows(dir) do
    if File.exists?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reduce(%{}, fn filename, acc ->
        path = Path.join(dir, filename)

        case load_workflow_file(path) do
          {:ok, workflow} ->
            Map.put(acc, workflow.id, workflow)

          {:error, reason} ->
            Logger.warning("Skipping workflow file #{filename}: #{reason}")
            acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("Failed to load workflows from #{dir}: #{Exception.message(e)}")
      %{}
  end

  defp load_workflow_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      workflow = deserialize_workflow(data)
      {:ok, workflow}
    else
      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Serialization ────────────────────────────────────────────────────

  defp serialize_workflow(workflow) do
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

  defp serialize_step(step) do
    %{
      "id" => step.id,
      "name" => step.name,
      "description" => step.description,
      "status" => to_string(step.status),
      "signal_mode" => if(step.signal_mode, do: to_string(step.signal_mode), else: nil),
      "tools_needed" => step.tools_needed || [],
      "acceptance_criteria" => step.acceptance_criteria,
      "result" => step.result,
      "started_at" => step.started_at,
      "completed_at" => step.completed_at
    }
  end

  defp deserialize_workflow(data) when is_map(data) do
    steps =
      (data["steps"] || [])
      |> Enum.map(&deserialize_step/1)

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

  defp deserialize_step(data) when is_map(data) do
    %Step{
      id: data["id"],
      name: data["name"],
      description: data["description"],
      status: parse_status(data["status"]),
      signal_mode: parse_signal_mode(data["signal_mode"]),
      tools_needed: data["tools_needed"] || [],
      acceptance_criteria: data["acceptance_criteria"],
      result: data["result"],
      started_at: data["started_at"],
      completed_at: data["completed_at"]
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────────

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

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate("wf")

  defp extract_name(description) do
    # Take first sentence or first 60 chars, whichever is shorter
    first_sentence =
      description
      |> String.split(~r/[.!?\n]/, parts: 2)
      |> List.first()
      |> String.trim()

    truncate(first_sentence, 60)
  end

  defp truncate(str, max_len),
    do: OptimalSystemAgent.Utils.Text.truncate(str, max_len)

  defp now_iso,
    do: OptimalSystemAgent.Utils.Text.now_iso()

  defp workflows_dir do
    Application.get_env(:optimal_system_agent, :workflows_dir, "~/.osa/workflows") |> Path.expand()
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

  defp parse_signal_mode(nil), do: nil
  defp parse_signal_mode("BUILD"), do: :build
  defp parse_signal_mode("EXECUTE"), do: :execute
  defp parse_signal_mode("ANALYZE"), do: :analyze
  defp parse_signal_mode("ASSIST"), do: :assist
  defp parse_signal_mode("MAINTAIN"), do: :maintain

  defp parse_signal_mode(mode) when is_binary(mode) do
    downcased = String.downcase(mode)

    try do
      String.to_existing_atom(downcased)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp parse_signal_mode(atom) when is_atom(atom), do: atom
  defp parse_signal_mode(_), do: nil
end
