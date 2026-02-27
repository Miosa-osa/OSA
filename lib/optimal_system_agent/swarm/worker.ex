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

  alias OptimalSystemAgent.Agent.{Roster, Tier}
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
    role_prompt = Roster.role_prompt(role)

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
