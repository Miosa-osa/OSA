defmodule OptimalSystemAgent.Fleet.Registry do
  @moduledoc """
  GenServer tracking all remote agents in the fleet.

  Manages agent registration, heartbeats, and status tracking.
  Each registered agent gets a Sentinel process (digital twin) started
  via the SentinelPool DynamicSupervisor.

  Emits bus events: :fleet_agent_registered, :fleet_agent_heartbeat,
  :fleet_agent_unreachable
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Fleet.Sentinel
  alias OptimalSystemAgent.Protocol.OSCP

  defstruct agents: %{},
            stats: %{total: 0, online: 0, unreachable: 0}

  # ── Client API ────────────────────────────────────────────────────

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a new agent with given capabilities. Starts a Sentinel."
  @spec register_agent(String.t(), list()) :: {:ok, pid()} | {:error, term()}
  def register_agent(agent_id, capabilities \\ []) do
    GenServer.call(__MODULE__, {:register, agent_id, capabilities})
  end

  @doc "Forward a heartbeat with metrics to the agent's sentinel."
  @spec heartbeat(String.t(), map()) :: :ok | {:error, :not_found}
  def heartbeat(agent_id, metrics \\ %{}) do
    GenServer.call(__MODULE__, {:heartbeat, agent_id, metrics})
  end

  @doc "List all registered agents with their status."
  @spec list_agents() :: list(map())
  def list_agents do
    GenServer.call(__MODULE__, :list_agents)
  end

  @doc "Get details for a single agent."
  @spec get_agent(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_agent(agent_id) do
    GenServer.call(__MODULE__, {:get_agent, agent_id})
  end

  @doc "Remove an agent and stop its sentinel."
  @spec remove_agent(String.t()) :: :ok | {:error, :not_found}
  def remove_agent(agent_id) do
    GenServer.call(__MODULE__, {:remove, agent_id})
  end

  @doc "Get fleet stats."
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # ── Server callbacks ──────────────────────────────────────────────

  @impl true
  def init(:ok) do
    Logger.info("[Fleet.Registry] Fleet registry started")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, agent_id, capabilities}, _from, state) do
    if Map.has_key?(state.agents, agent_id) do
      {:reply, {:error, :already_registered}, state}
    else
      case start_sentinel(agent_id, capabilities) do
        {:ok, pid} ->
          agent_info = %{
            sentinel_pid: pid,
            status: :online,
            capabilities: capabilities,
            registered_at: DateTime.utc_now(),
            last_heartbeat: DateTime.utc_now()
          }

          new_agents = Map.put(state.agents, agent_id, agent_info)
          new_state = %{state | agents: new_agents} |> update_stats()

          Logger.info("[Fleet.Registry] Registered agent #{agent_id}")

          try do
            oscp_event = OSCP.signal(
              "urn:osa:fleet:registry",
              "agent.registered",
              %{agent_id: agent_id, capabilities: capabilities}
            )
            Bus.emit(:system_event, OSCP.to_bus_event(oscp_event))
          rescue
            _ -> :ok
          end

          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          Logger.error(
            "[Fleet.Registry] Failed to start sentinel for #{agent_id}: #{inspect(reason)}"
          )

          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:heartbeat, agent_id, metrics}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent_info} ->
        Sentinel.update_heartbeat(agent_info.sentinel_pid, metrics)

        updated_info = %{agent_info | last_heartbeat: DateTime.utc_now(), status: :online}
        new_agents = Map.put(state.agents, agent_id, updated_info)
        new_state = %{state | agents: new_agents} |> update_stats()

        try do
          oscp_event = OSCP.heartbeat(agent_id, metrics)
          Bus.emit(:system_event, OSCP.to_bus_event(oscp_event))
        rescue
          _ -> :ok
        end

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    agents =
      Enum.map(state.agents, fn {agent_id, info} ->
        status = try_get_sentinel_status(info.sentinel_pid, info)

        %{
          agent_id: agent_id,
          status: status.status,
          capabilities: info.capabilities,
          registered_at: info.registered_at,
          last_heartbeat: info.last_heartbeat
        }
      end)

    {:reply, agents, state}
  end

  def handle_call({:get_agent, agent_id}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, info} ->
        status = try_get_sentinel_status(info.sentinel_pid, info)
        result = Map.merge(status, %{agent_id: agent_id, registered_at: info.registered_at})
        {:reply, {:ok, result}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:remove, agent_id}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, info} ->
        DynamicSupervisor.terminate_child(
          OptimalSystemAgent.Fleet.SentinelPool,
          info.sentinel_pid
        )

        new_agents = Map.delete(state.agents, agent_id)
        new_state = %{state | agents: new_agents} |> update_stats()

        Logger.info("[Fleet.Registry] Removed agent #{agent_id}")
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp start_sentinel(agent_id, capabilities) do
    DynamicSupervisor.start_child(
      OptimalSystemAgent.Fleet.SentinelPool,
      {Sentinel, agent_id: agent_id, capabilities: capabilities}
    )
  end

  defp update_stats(state) do
    total = map_size(state.agents)

    {online, unreachable} =
      Enum.reduce(state.agents, {0, 0}, fn {_id, info}, {on, un} ->
        case info.status do
          :online -> {on + 1, un}
          :unreachable -> {on, un + 1}
          _ -> {on, un}
        end
      end)

    %{state | stats: %{total: total, online: online, unreachable: unreachable}}
  end

  defp try_get_sentinel_status(pid, fallback_info) do
    try do
      Sentinel.get_status(pid)
    catch
      :exit, _ ->
        %{
          status: :unreachable,
          last_heartbeat: fallback_info.last_heartbeat,
          capabilities: fallback_info.capabilities,
          cpu_load: 0.0,
          memory_mb: 0,
          disk_gb: 0.0,
          current_task: nil,
          last_error: nil
        }
    end
  end
end
