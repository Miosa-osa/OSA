defmodule OptimalSystemAgent.Swarm.Worker do
  @moduledoc """
  An individual agent within a swarm.

  Each worker has:
  - A role (researcher, coder, reviewer, planner, critic, writer, tester, architect)
  - A specialised system prompt for that role
  - Access to the shared Mailbox for inter-agent communication
  - Its own isolated conversation context

  Lifecycle:
    1. Started by the Orchestrator under DynamicSupervisor
    2. Receives an `assign/2` call with a specific subtask
    3. Calls the LLM with the role system prompt + mailbox context + subtask
    4. Posts result to Mailbox
    5. Replies to the caller with {:ok, result} | {:error, reason}
    6. Exits normally (restart: :temporary)

  Workers are `:temporary` — they are expected to exit after completing
  their assigned task. If they crash, the DynamicSupervisor does NOT restart
  them; instead the Orchestrator handles failure via the return value from
  `assign/3`.
  """
  use GenServer, restart: :temporary
  require Logger

  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Swarm.Mailbox

  defstruct [
    :id,
    :swarm_id,
    :role,
    # :idle | :working | :done | :failed
    status: :idle,
    messages: [],
    result: nil,
    started_at: nil
  ]

  # Role-specific system prompts — each shapes the LLM's behaviour for
  # that agent's specialisation within the swarm.
  @role_prompts %{
    researcher: """
    You are a research specialist within a multi-agent swarm.
    Your job is to gather information, find relevant data, and provide comprehensive
    research results. Be thorough, cite sources when available, and summarise key
    findings clearly so other agents in the swarm can build on your work.
    Output your findings as structured, actionable text.
    """,
    coder: """
    You are a coding specialist within a multi-agent swarm.
    Your job is to write clean, tested, production-quality code.
    Follow best practices: meaningful names, error handling, small functions.
    Include inline comments for non-obvious logic. Wrap code in markdown fences
    with the correct language tag. Do not add unnecessary boilerplate.
    """,
    reviewer: """
    You are a code review specialist within a multi-agent swarm.
    Your job is to review code and proposals for bugs, security issues,
    performance problems, and style violations. Be constructive and specific —
    cite the exact line or pattern you are commenting on. Categorise findings
    as CRITICAL / MAJOR / MINOR and provide a concrete fix for each.
    """,
    planner: """
    You are a planning specialist within a multi-agent swarm.
    Your job is to break down complex tasks into actionable steps, identify
    dependencies between steps, and create a clear execution plan. Output the
    plan as a numbered list with estimated effort and dependencies noted.
    """,
    critic: """
    You are a critical analyst within a multi-agent swarm.
    Your job is to find flaws, edge cases, and potential failure modes in
    proposed solutions. Challenge assumptions. Be thorough but constructive —
    your goal is to make the solution stronger, not to reject it outright.
    """,
    writer: """
    You are a technical writer within a multi-agent swarm.
    Your job is to create clear, comprehensive documentation: README files,
    API references, architecture guides, and usage examples. Write for the
    target audience (specified in the task). Use plain language, avoid jargon
    unless necessary, and structure content with headings and examples.
    """,
    tester: """
    You are a testing specialist within a multi-agent swarm.
    Your job is to write comprehensive test cases covering happy paths, edge
    cases, error conditions, and boundary values. Identify what is NOT tested
    and explain why it should be. Provide concrete test code where asked.
    """,
    architect: """
    You are a system architect within a multi-agent swarm.
    Your job is to design scalable, maintainable system architectures.
    Consider trade-offs explicitly: consistency vs availability, simplicity vs
    flexibility, build vs buy. Produce ADRs or diagrams-as-code where helpful.
    Think in bounded contexts and clear API boundaries.
    """,
    # Extended roles from Agent-Dispatch / OSA Roster
    lead: """
    You are the LEAD orchestrator within a multi-agent swarm.
    Synthesize and merge the work of other agents. Resolve conflicts between
    outputs. Make ship/no-ship decisions based on quality. Produce the final report.
    """,
    backend: """
    You are a BACKEND specialist within a multi-agent swarm.
    Write server-side code: APIs, handlers, services, business logic.
    Follow existing patterns. Handle all error paths. Production quality only.
    """,
    frontend: """
    You are a FRONTEND specialist within a multi-agent swarm.
    Write client-side code: components, pages, state management, styling.
    Follow design system patterns. Ensure accessibility (WCAG 2.1 AA).
    """,
    data: """
    You are a DATA specialist within a multi-agent swarm.
    Handle database schemas, migrations, queries, and data integrity.
    Optimize queries. Handle race conditions. Your work is foundational.
    """,
    design: """
    You are a DESIGN specialist within a multi-agent swarm.
    Create design specifications, tokens, color palettes, typography scales.
    Audit accessibility. Ensure visual consistency. You define what, not how.
    """,
    infra: """
    You are an INFRASTRUCTURE specialist within a multi-agent swarm.
    Write Dockerfiles, CI/CD pipelines, deployment configs. Optimize for production.
    Do not modify application logic — only operational concerns.
    """,
    qa: """
    You are a QA specialist within a multi-agent swarm.
    Write comprehensive tests. Verify implementations match acceptance criteria.
    Run test suites and report results. Security audit when relevant.
    """,
    red_team: """
    You are the RED TEAM within a multi-agent swarm.
    Review all output for security vulnerabilities and missed edge cases.
    Produce findings report with severity: CRITICAL/HIGH/MEDIUM/LOW.
    You do NOT fix code — you find problems.
    """,
    services: """
    You are a SERVICES specialist within a multi-agent swarm.
    Write integration code: external APIs, workers, background jobs.
    Handle robust error recovery, retries, and circuit breakers.
    """
  }

  @default_role_prompt """
  You are a specialist agent within a multi-agent swarm.
  Complete the assigned subtask thoroughly and clearly, then summarise your result.
  """

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Assign a subtask to this worker and wait for completion.
  Returns {:ok, result_text} | {:error, reason}.
  Blocks the caller; run inside a Task for true parallelism.
  Timeout defaults to 5 minutes.
  """
  def assign(pid, task_description, timeout \\ 300_000) do
    GenServer.call(pid, {:assign, task_description}, timeout)
  end

  @doc "Get the current status and result of this worker."
  def get_result(pid) do
    GenServer.call(pid, :get_result)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(%{id: id, swarm_id: swarm_id, role: role} = _opts) do
    state = %__MODULE__{
      id: id,
      swarm_id: swarm_id,
      role: role,
      started_at: DateTime.utc_now()
    }

    Logger.info("Swarm worker started: id=#{id} role=#{role} swarm=#{swarm_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:assign, task_description}, _from, state) do
    state = %{state | status: :working}

    # Build messages: system prompt (role) + optional mailbox context + task
    system_prompt = build_system_prompt(state.role, state.swarm_id)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: task_description}
    ]

    # Tier-aware model routing: map role to tier, then to model
    tier = role_to_tier(state.role)
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    model = Tier.model_for(tier, provider)
    temperature = Tier.temperature(tier)

    Logger.debug(
      "Worker #{state.id} (#{state.role}) calling LLM [#{tier}/#{model}] for task: #{String.slice(task_description, 0, 80)}..."
    )

    result =
      case Providers.chat(messages, temperature: temperature, model: model) do
        {:ok, %{content: content}} when is_binary(content) and content != "" ->
          # Post result to swarm mailbox so peers can read it
          Mailbox.post(state.swarm_id, state.id, content)
          {:ok, content}

        {:ok, %{content: content}} ->
          fallback = "(Worker #{state.role} produced no content)"
          Mailbox.post(state.swarm_id, state.id, fallback)
          {:ok, fallback <> " raw=#{inspect(content)}"}

        {:error, reason} ->
          error_msg = "Worker #{state.id} (#{state.role}) LLM error: #{inspect(reason)}"
          Logger.error(error_msg)
          {:error, reason}
      end

    {status, result_value} =
      case result do
        {:ok, text} -> {:done, text}
        {:error, _} -> {:failed, nil}
      end

    state = %{state | status: status, result: result_value}

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_result, _from, state) do
    {:reply, %{status: state.status, result: state.result, role: state.role, id: state.id}, state}
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  # Map swarm worker roles to tiers for model selection.
  # Lead/architect = elite, most roles = specialist, simple roles = utility.
  defp role_to_tier(:lead), do: :elite
  defp role_to_tier(:architect), do: :elite
  defp role_to_tier(:researcher), do: :specialist
  defp role_to_tier(:coder), do: :specialist
  defp role_to_tier(:reviewer), do: :specialist
  defp role_to_tier(:planner), do: :specialist
  defp role_to_tier(:backend), do: :specialist
  defp role_to_tier(:frontend), do: :specialist
  defp role_to_tier(:data), do: :specialist
  defp role_to_tier(:services), do: :specialist
  defp role_to_tier(:red_team), do: :specialist
  defp role_to_tier(:qa), do: :specialist
  defp role_to_tier(:infra), do: :specialist
  defp role_to_tier(:design), do: :utility
  defp role_to_tier(:critic), do: :specialist
  defp role_to_tier(:writer), do: :utility
  defp role_to_tier(:tester), do: :specialist
  defp role_to_tier(_), do: :specialist

  defp build_system_prompt(role, swarm_id) do
    role_prompt = Map.get(@role_prompts, role, @default_role_prompt)

    # Inject mailbox context so this worker can see what peers have done
    mailbox_context = Mailbox.build_context(swarm_id)

    parts = [
      String.trim(role_prompt),
      mailbox_context
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
