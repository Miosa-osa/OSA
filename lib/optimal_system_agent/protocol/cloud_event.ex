defmodule OptimalSystemAgent.Protocol.CloudEvent do
  @moduledoc """
  CloudEvent v1.0.2 envelope.

  Thin struct + encode/decode/conversion helpers for the Signal Theory
  event system.
  """

  @type t :: %__MODULE__{
          specversion: String.t(),
          type: String.t(),
          source: String.t(),
          subject: String.t() | nil,
          id: String.t(),
          time: String.t() | nil,
          datacontenttype: String.t() | nil,
          data: term()
        }

  defstruct specversion: "1.0",
            type: nil,
            source: nil,
            subject: nil,
            id: "",
            time: nil,
            datacontenttype: "application/json",
            data: nil

  @doc "Build a CloudEvent from an attribute map. Raises KeyError if :type or :source is missing."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    # Raises KeyError when key is absent — matches test expectations
    type = Map.fetch!(attrs, :type)
    source = Map.fetch!(attrs, :source)

    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()
    raw_time = Map.get(attrs, :time) || Map.get(attrs, "time") || DateTime.utc_now()
    time = format_time(raw_time)

    %__MODULE__{
      specversion: Map.get(attrs, :specversion, "1.0"),
      type: to_string(type),
      source: to_string(source),
      subject: Map.get(attrs, :subject) || Map.get(attrs, "subject"),
      id: to_string(id),
      time: time,
      datacontenttype: Map.get(attrs, :datacontenttype, "application/json"),
      data: Map.get(attrs, :data) || Map.get(attrs, "data")
    }
  end

  @doc "Encode a CloudEvent to a JSON string."
  @spec encode(t()) :: {:ok, String.t()} | {:error, String.t()}
  def encode(%__MODULE__{type: nil}), do: {:error, "type is required"}
  def encode(%__MODULE__{source: nil}), do: {:error, "source is required"}

  def encode(%__MODULE__{} = event) do
    map =
      %{
        "specversion" => event.specversion,
        "type" => event.type,
        "source" => event.source,
        "id" => event.id,
        "time" => event.time,
        "datacontenttype" => event.datacontenttype,
        "data" => event.data
      }
      |> maybe_put("subject", event.subject)

    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "JSON encode error: #{inspect(reason)}"}
    end
  end

  @doc "Decode a JSON string into a CloudEvent struct."
  @spec decode(map() | String.t()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      {:error, reason} -> {:error, "JSON decode error: #{inspect(reason)}"}
    end
  end

  def decode(map) when is_map(map) do
    type = Map.get(map, "type")
    source = Map.get(map, "source")

    cond do
      is_nil(type) or type == "" ->
        {:error, "type is required"}

      is_nil(source) or source == "" ->
        {:error, "source is required"}

      true ->
        event = %__MODULE__{
          specversion: Map.get(map, "specversion", "1.0"),
          type: to_string(type),
          source: to_string(source),
          subject: Map.get(map, "subject"),
          id: to_string(Map.get(map, "id") || generate_id()),
          time: Map.get(map, "time"),
          datacontenttype: Map.get(map, "datacontenttype"),
          data: Map.get(map, "data")
        }

        {:ok, event}
    end
  end

  def decode(_), do: {:error, "expected a map or JSON string"}

  @doc "Convert an internal bus event map (with :event key) to a CloudEvent struct."
  @spec from_bus_event(map()) :: t()
  def from_bus_event(event_map) when is_map(event_map) do
    event_name = Map.fetch!(event_map, :event)
    session_id = Map.get(event_map, :session_id, "unknown")

    data =
      event_map
      |> Map.drop([:event, :session_id, :subject])

    new(%{
      type: "com.osa.#{event_name}",
      source: "urn:osa:agent:#{session_id}",
      subject: Map.get(event_map, :subject),
      data: data
    })
  end

  @doc "Convert a CloudEvent struct back to an internal bus event map."
  @spec to_bus_event(t()) :: map()
  def to_bus_event(%__MODULE__{} = event) do
    event_atom =
      event.type
      |> String.replace_prefix("com.osa.", "")
      |> String.to_atom()

    data_fields =
      case event.data do
        nil -> %{}
        map when is_map(map) -> map
        _ -> %{}
      end

    Map.merge(data_fields, %{
      event: event_atom,
      source: event.source
    })
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp generate_id do
    "evt_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_time(other) when is_binary(other), do: other
  defp format_time(other), do: to_string(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
