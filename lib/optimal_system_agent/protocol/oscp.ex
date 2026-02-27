defmodule OptimalSystemAgent.Protocol.OSCP do
  @moduledoc """
  OSCP — Optimal Signal Communication Protocol.

  CloudEvents 1.0-based event envelope for agent-to-agent and
  agent-to-orchestrator communication. Thin typed wrapper over
  `Protocol.CloudEvent`.

  ## Event Types

  | Type               | Direction              | Purpose                       |
  |--------------------|------------------------|-------------------------------|
  | `oscp.heartbeat`   | Agent → Orchestrator   | Health: cpu, memory, status   |
  | `oscp.instruction` | Orchestrator → Agent   | Task assignment               |
  | `oscp.result`      | Agent → Orchestrator   | Task outcome                  |
  | `oscp.signal`      | Any → Any              | Generic (subtype field)       |
  """

  alias OptimalSystemAgent.Protocol.CloudEvent

  @event_types ~w(oscp.heartbeat oscp.instruction oscp.result oscp.signal)
  @source_prefix "urn:osa:agent:"

  # ── Typed Constructors ───────────────────────────────────────────

  @doc "Build a heartbeat CloudEvent with agent metrics."
  @spec heartbeat(String.t(), map()) :: CloudEvent.t()
  def heartbeat(agent_id, metrics) when is_binary(agent_id) and is_map(metrics) do
    CloudEvent.new(%{
      type: "oscp.heartbeat",
      source: @source_prefix <> agent_id,
      subject: agent_id,
      data: Map.merge(metrics, %{agent_id: agent_id})
    })
  end

  @doc "Build an instruction CloudEvent for task dispatch."
  @spec instruction(String.t(), String.t(), map(), keyword()) :: CloudEvent.t()
  def instruction(agent_id, task_id, payload, opts \\ []) do
    data = %{
      agent_id: agent_id,
      task_id: task_id,
      payload: payload,
      priority: Keyword.get(opts, :priority, 0),
      lease_ms: Keyword.get(opts, :lease_ms, 300_000)
    }

    CloudEvent.new(%{
      type: "oscp.instruction",
      source: "urn:osa:orchestrator",
      subject: task_id,
      data: data
    })
  end

  @doc "Build a result CloudEvent reporting task outcome."
  @spec result(String.t(), String.t(), map()) :: CloudEvent.t()
  def result(agent_id, task_id, outcome) when is_map(outcome) do
    data = Map.merge(outcome, %{agent_id: agent_id, task_id: task_id})

    CloudEvent.new(%{
      type: "oscp.result",
      source: @source_prefix <> agent_id,
      subject: task_id,
      data: data
    })
  end

  @doc "Build a generic signal CloudEvent with a subtype."
  @spec signal(String.t(), String.t(), map()) :: CloudEvent.t()
  def signal(source, subtype, data) when is_binary(subtype) and is_map(data) do
    CloudEvent.new(%{
      type: "oscp.signal",
      source: source,
      subject: subtype,
      data: Map.put(data, :subtype, subtype)
    })
  end

  # ── Validation ───────────────────────────────────────────────────

  @doc "Check if a type string is a valid OSCP event type."
  @spec valid_type?(String.t()) :: boolean()
  def valid_type?(type) when is_binary(type), do: type in @event_types

  @doc "Validate a CloudEvent has a valid OSCP type and required fields."
  @spec validate(CloudEvent.t()) :: :ok | {:error, String.t()}
  def validate(%CloudEvent{type: type}) do
    if valid_type?(type) do
      :ok
    else
      {:error, "invalid OSCP type: #{type}, expected one of #{inspect(@event_types)}"}
    end
  end

  # ── Encode / Decode ──────────────────────────────────────────────

  @doc "Encode an OSCP CloudEvent to JSON."
  @spec encode(CloudEvent.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%CloudEvent{} = event), do: CloudEvent.encode(event)

  @doc "Decode JSON to CloudEvent and validate as OSCP type."
  @spec decode(String.t()) :: {:ok, CloudEvent.t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    with {:ok, event} <- CloudEvent.decode(json),
         :ok <- validate(event) do
      {:ok, event}
    end
  end

  # ── Bus Integration ──────────────────────────────────────────────

  @doc "Convert an internal Bus event map to an OSCP CloudEvent."
  @spec from_bus_event(map()) :: CloudEvent.t()
  def from_bus_event(%{event: event_type} = event_map) do
    oscp_type = bus_event_to_oscp_type(event_type)
    agent_id = Map.get(event_map, :agent_id, "unknown")
    source = @source_prefix <> to_string(agent_id)

    CloudEvent.new(%{
      type: oscp_type,
      source: source,
      subject: Map.get(event_map, :subject) || Map.get(event_map, :task_id),
      data: Map.drop(event_map, [:event, :subject])
    })
  end

  @doc "Convert an OSCP CloudEvent to an internal Bus event map."
  @spec to_bus_event(CloudEvent.t()) :: map()
  def to_bus_event(%CloudEvent{} = event) do
    event_atom = oscp_type_to_bus_event(event.type)
    Map.merge(event.data, %{event: event_atom, source: event.source})
  end

  @doc "Return the list of known OSCP event types."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  # ── Private ──────────────────────────────────────────────────────

  defp bus_event_to_oscp_type(:fleet_agent_heartbeat), do: "oscp.heartbeat"
  defp bus_event_to_oscp_type(:fleet_agent_registered), do: "oscp.signal"
  defp bus_event_to_oscp_type(:fleet_agent_unreachable), do: "oscp.signal"
  defp bus_event_to_oscp_type(:task_enqueued), do: "oscp.instruction"
  defp bus_event_to_oscp_type(:task_completed), do: "oscp.result"
  defp bus_event_to_oscp_type(:task_failed), do: "oscp.result"
  defp bus_event_to_oscp_type(:task_leased), do: "oscp.instruction"
  defp bus_event_to_oscp_type(_other), do: "oscp.signal"

  defp oscp_type_to_bus_event("oscp.heartbeat"), do: :fleet_agent_heartbeat
  defp oscp_type_to_bus_event("oscp.instruction"), do: :task_enqueued
  defp oscp_type_to_bus_event("oscp.result"), do: :task_completed
  defp oscp_type_to_bus_event("oscp.signal"), do: :system_event
end
