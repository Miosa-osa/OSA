defmodule OptimalSystemAgent.Events.Event do
  @moduledoc "CloudEvents v1.0.2 event struct with Signal Theory extensions."

  defstruct [
    :id,
    :type,
    :source,
    :time,
    :subject,
    :data,
    :dataschema,
    :parent_id,
    :session_id,
    :correlation_id,
    :signal_mode,
    :signal_genre,
    :signal_type,
    :signal_format,
    :signal_structure,
    :signal_sn,
    specversion: "1.0.2",
    datacontenttype: "application/json",
    extensions: %{}
  ]

  @type signal_mode :: :execute | :build | :analyze | :maintain | :assist
  @type signal_genre :: :direct | :inform | :commit | :decide | :express
  @type signal_type :: atom()
  @type signal_format :: :text | :code | :json | :markdown | :binary
  @type t :: %__MODULE__{}

  def new(type, source), do: new(type, source, nil, [])
  def new(type, source, data), do: new(type, source, data, [])

  def new(type, source, data, opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      type: type,
      source: source,
      data: data,
      time: Keyword.get(opts, :time, DateTime.utc_now()),
      subject: Keyword.get(opts, :subject),
      dataschema: Keyword.get(opts, :dataschema),
      session_id: Keyword.get(opts, :session_id),
      parent_id: Keyword.get(opts, :parent_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      signal_mode: Keyword.get(opts, :signal_mode),
      signal_genre: Keyword.get(opts, :signal_genre),
      signal_type: Keyword.get(opts, :signal_type),
      signal_format: Keyword.get(opts, :signal_format),
      signal_structure: Keyword.get(opts, :signal_structure),
      signal_sn: Keyword.get(opts, :signal_sn),
      extensions: Keyword.get(opts, :extensions, %{})
    }
  end

  def child(parent, type, source), do: child(parent, type, source, nil, [])
  def child(parent, type, source, data), do: child(parent, type, source, data, [])

  def child(%__MODULE__{} = parent, type, source, data, opts) do
    defaults = [
      parent_id: parent.id,
      session_id: parent.session_id,
      correlation_id: parent.correlation_id || parent.id
    ]

    new(type, source, data, Keyword.merge(defaults, opts))
  end

  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def to_cloud_event(%__MODULE__{} = event) do
    base = %{
      "specversion" => event.specversion,
      "type" => to_string(event.type),
      "source" => event.source,
      "id" => event.id,
      "time" => event.time && DateTime.to_iso8601(event.time),
      "datacontenttype" => event.datacontenttype
    }

    base
    |> maybe_put("data", event.data)
    |> maybe_put("subject", event.subject)
    |> maybe_put("dataschema", event.dataschema)
    |> maybe_put("parent_id", event.parent_id)
    |> maybe_put("session_id", event.session_id)
    |> maybe_put("correlation_id", event.correlation_id)
    |> maybe_put_signal("signal_mode", event.signal_mode)
    |> maybe_put_signal("signal_genre", event.signal_genre)
    |> maybe_put_signal("signal_type", event.signal_type)
    |> maybe_put_signal("signal_format", event.signal_format)
    |> maybe_put_signal("signal_structure", event.signal_structure)
    |> maybe_put("signal_sn", event.signal_sn)
    |> merge_extensions(event.extensions)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_signal(map, _key, nil), do: map
  defp maybe_put_signal(map, key, val), do: Map.put(map, key, to_string(val))

  defp merge_extensions(map, ext) when map_size(ext) == 0, do: map

  defp merge_extensions(map, ext) do
    string_ext = for {k, v} <- ext, into: %{}, do: {to_string(k), v}
    Map.merge(map, string_ext)
  end

  defp generate_id do
    ts = System.system_time(:microsecond)
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "evt_#{ts}_#{rand}"
  end
end
