defmodule OptimalSystemAgent.Security.TrafficIngest do
  @moduledoc """
  Turn API contracts and captured HTTP into finding notes.

  Strix's HTTP intercepting proxy is the thing that lets an agent *see*
  traffic. OSA does not ship a live MITM. This module is the ingest half:
  HAR (Chrome/Caido/Burp export) and OpenAPI/Swagger specs become endpoint
  notes the rest of the intelligence layer already understands, so the agent
  tests declared surface instead of crawling blind.
  """

  @doc "Ingest HAR JSON (`log.entries`) into finding notes."
  @spec har(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def har(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} -> har_map(map)
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  def har(_), do: {:error, "HAR payload must be a string"}

  @doc "Ingest an OpenAPI 3 / Swagger 2 JSON spec into endpoint notes."
  @spec openapi(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def openapi(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} -> openapi_map(map)
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  def openapi(_), do: {:error, "OpenAPI payload must be a string"}

  defp har_map(%{"log" => %{"entries" => entries}}) when is_list(entries) do
    notes =
      entries
      |> Enum.flat_map(&har_entry/1)
      |> Enum.uniq_by(&{&1.target, &1.endpoints})

    {:ok, notes}
  end

  defp har_map(_), do: {:error, "not a HAR log (missing log.entries)"}

  defp har_entry(%{"request" => req} = entry) do
    url = req["url"] || ""
    method = req["method"] || "GET"
    status = get_in(entry, ["response", "status"])

    if url == "" do
      []
    else
      [
        %{
          category: :finding,
          content: "HAR #{method} #{url}" <> if(status, do: " -> #{status}", else: ""),
          target: url,
          source: "har",
          endpoints: [%{path: path_of(url), methods: [method]}],
          confidence: :medium,
          metadata: %{"status" => status, "method" => method}
        }
      ]
    end
  end

  defp har_entry(_), do: []

  defp openapi_map(map) when is_map(map) do
    paths = map["paths"] || %{}
    servers = map["servers"] || []
    base = get_in(List.first(servers) || %{}, ["url"]) || map["host"] || "spec"

    notes =
      Enum.flat_map(paths, fn {path, ops} ->
        methods =
          ops
          |> Map.keys()
          |> Enum.filter(&(&1 in ~w(get post put patch delete head options trace)))
          |> Enum.map(&String.upcase/1)

        if methods == [] do
          []
        else
          [
            %{
              category: :finding,
              content: "OpenAPI #{Enum.join(methods, ",")} #{path}",
              target: join_url(base, path),
              source: "openapi",
              endpoints: [%{path: path, methods: methods}],
              confidence: :high,
              metadata: %{"spec_path" => path}
            }
          ]
        end
      end)

    {:ok, notes}
  end

  defp path_of(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> "/"
    end
  end

  defp join_url(base, path) do
    base = String.trim_trailing(to_string(base), "/")
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    base <> path
  end
end
