defmodule OptimalSystemAgent.Protocol.CloudEvent do
  @moduledoc """
  CloudEvents 1.0 protocol for external event interop.

  Provides encoding/decoding of CloudEvents 1.0 JSON format for
  integration with external systems via the event bus.
  """

  @enforce_keys [:type, :source]
  defstruct specversion: "1.0",
            type: nil,
            source: nil,
            subject: nil,
            id: nil,
            time: nil,
            datacontenttype: "application/json",
            data: %{}

  @type t :: %__MODULE__{
          specversion: String.t(),
          type: String.t(),
          source: String.t(),
          subject: String.t() | nil,
          id: String.t(),
          time: String.t(),
          datacontenttype: String.t(),
          data: map()
        }

  @doc "Create a new CloudEvent with auto-generated id and time."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      specversion: "1.0",
      type: Map.fetch!(attrs, :type),
      source: Map.fetch!(attrs, :source),
      subject: Map.get(attrs, :subject),
      id: Map.get(attrs, :id, generate_id()),
      time: Map.get(attrs, :time, DateTime.utc_now() |> DateTime.to_iso8601()),
      datacontenttype: Map.get(attrs, :datacontenttype, "application/json"),
      data: Map.get(attrs, :data, %{})
    }
  end

  @doc "Encode a CloudEvent to JSON string."
  @spec encode(t()) :: {:ok, String.t()} | {:error, String.t()}
  def encode(%__MODULE__{} = event) do
    with :ok <- validate(event) do
      map = %{
        specversion: event.specversion,
        type: event.type,
        source: event.source,
        id: event.id,
        time: event.time,
        datacontenttype: event.datacontenttype,
        data: event.data
      }

      map = if event.subject, do: Map.put(map, :subject, event.subject), else: map
      Jason.encode(map)
    end
  end

  @doc "Decode JSON string to CloudEvent struct."
  @spec decode(String.t()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      try do
        event = %__MODULE__{
          specversion: map["specversion"] || "1.0",
          type: map["type"],
          source: map["source"],
          subject: map["subject"],
          id: map["id"] || generate_id(),
          time: map["time"] || DateTime.utc_now() |> DateTime.to_iso8601(),
          datacontenttype: map["datacontenttype"] || "application/json",
          data: map["data"] || %{}
        }

        validate_and_return(event)
      rescue
        _ -> {:error, "Invalid CloudEvent format"}
      end
    end
  end

  @doc "Convert internal Bus event to CloudEvent."
  @spec from_bus_event(map()) :: t()
  def from_bus_event(%{event: event_type} = event_map) do
    session_id = Map.get(event_map, :session_id, "unknown")

    new(%{
      type: "com.osa.#{event_type}",
      source: "urn:osa:agent:#{session_id}",
      subject: Map.get(event_map, :subject),
      data: Map.drop(event_map, [:event, :session_id, :subject])
    })
  end

  @doc "Convert CloudEvent to internal Bus event format."
  @spec to_bus_event(t()) :: map()
  def to_bus_event(%__MODULE__{} = event) do
    stripped = String.replace(event.type, "com.osa.", "")

    event_type =
      try do
        String.to_existing_atom(stripped)
      rescue
        ArgumentError -> stripped
      end

    Map.merge(event.data, %{event: event_type, source: event.source})
  end

  # ── Private ──────────────────────────────────────────────────────

  defp validate(%__MODULE__{type: nil}), do: {:error, "type is required"}
  defp validate(%__MODULE__{source: nil}), do: {:error, "source is required"}
  defp validate(%__MODULE__{}), do: :ok

  defp validate_and_return(event) do
    case validate(event) do
      :ok -> {:ok, event}
      error -> error
    end
  end


  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate("evt")
end
