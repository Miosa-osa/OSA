defmodule OptimalSystemAgent.Security.ReconIngest do
  @moduledoc """
  Parse scanner output into structured-note-shaped maps.

  The intelligence layer already knows how to store notes and grow the
  ShadowGraph from them. This module is the missing adapter: nmap XML,
  httpx/nuclei/naabu JSONL, and subfinder text become those notes without
  the agent transcribing by hand.
  """

  @doc "Ingest from a map (`tool`, `format`, `payload`) for the security_intel tool."
  @spec ingest(map()) :: {:ok, [map()]} | {:error, String.t()}
  def ingest(%{} = input) do
    tool = Map.get(input, "tool") || Map.get(input, :tool)
    format = Map.get(input, "format") || Map.get(input, :format)
    payload = Map.get(input, "payload") || Map.get(input, :payload)
    ingest(tool, format, payload)
  end

  @spec ingest(atom() | String.t(), atom() | String.t(), String.t()) ::
          {:ok, [map()]} | {:error, String.t()}
  def ingest(_tool, _format, payload) when payload in [nil, ""] do
    {:ok, []}
  end

  def ingest(tool, format, payload) when is_binary(payload) do
    t = normalize(tool)
    f = normalize(format)

    case {t, f} do
      {:nmap, :xml} -> {:ok, parse_nmap_xml(payload)}
      {:httpx, fmt} when fmt in [:jsonl, :json] -> {:ok, parse_httpx(payload)}
      {:subfinder, fmt} when fmt in [:text, :jsonl] -> {:ok, parse_subfinder(payload)}
      {:nuclei, fmt} when fmt in [:jsonl, :json] -> {:ok, parse_nuclei(payload)}
      {:naabu, fmt} when fmt in [:jsonl, :json] -> {:ok, parse_naabu(payload)}
      _ -> {:error, "unknown tool/format: #{inspect(t)}/#{inspect(f)}"}
    end
  end

  def ingest(_, _, _), do: {:error, "payload must be a string"}

  defp normalize(v) when is_atom(v), do: v

  defp normalize(v) when is_binary(v) do
    try do
      String.to_existing_atom(String.downcase(v))
    rescue
      ArgumentError -> :unknown
    end
  end

  defp normalize(_), do: :unknown

  # ── nmap XML (subset) ───────────────────────────────────────────────────

  defp parse_nmap_xml(xml) do
    hosts = Regex.scan(~r/<host\b.*?<\/host>/s, xml) |> Enum.map(&hd/1)

    Enum.flat_map(hosts, fn host_xml ->
      if host_xml =~ ~r/<status\s+state="up"/ or not (host_xml =~ ~r/<status\s+state="down"/) do
        case Regex.run(~r/<address\s+addr="([^"]+)"/, host_xml) do
          [_, addr] ->
            services =
              Regex.scan(
                ~r|<port\s+protocol="([^"]+)"\s+portid="(\d+)">.*?<state\s+state="open"[^/]*/>.*?(?:<service\s+([^>]+)>)?|s,
                host_xml
              )
              |> Enum.map(fn
                [_, proto, port, svc_attrs] ->
                  %{
                    port: String.to_integer(port),
                    protocol: proto,
                    product: attr(svc_attrs, "product") || attr(svc_attrs, "name") || "",
                    version: attr(svc_attrs, "version") || ""
                  }

                [_, proto, port] ->
                  %{port: String.to_integer(port), protocol: proto, product: "", version: ""}
              end)

            if services == [] and host_xml =~ ~r/state="down"/ do
              []
            else
              [
                %{
                  category: :finding,
                  content: "nmap host #{addr}" <> service_summary(services),
                  target: addr,
                  source: "nmap",
                  services: services,
                  port: services |> List.first() |> then(&(&1 && Integer.to_string(&1.port))),
                  confidence: :medium,
                  metadata: %{}
                }
              ]
            end

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp attr(nil, _), do: nil

  defp attr(attrs, name) do
    case Regex.run(~r/#{name}="([^"]*)"/, attrs) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp service_summary([]), do: ""

  defp service_summary(svcs),
    do: " (" <> Enum.map_join(svcs, ", ", &"#{&1.port}/#{&1.protocol}") <> ")"

  # ── httpx JSONL ─────────────────────────────────────────────────────────

  defp parse_httpx(payload) do
    payload
    |> json_lines()
    |> Enum.map(fn obj ->
      url = obj["url"] || obj["input"] || ""
      host = obj["host"] || host_of(url)
      port = obj["port"]
      tech = List.wrap(obj["tech"] || obj["technologies"] || [])

      %{
        category: :finding,
        content: httpx_content(obj, url),
        target: if(url != "", do: url, else: host),
        source: "httpx",
        port: port && to_string(port),
        technologies: Enum.map(tech, fn t -> %{name: to_string(t), version: ""} end),
        endpoints: [%{path: path_of(url), methods: ["GET"]}],
        confidence: :medium,
        metadata: %{"status_code" => obj["status_code"], "title" => obj["title"]}
      }
    end)
    |> Enum.reject(&(&1.target in [nil, ""]))
  end

  defp httpx_content(obj, url) do
    status = obj["status_code"]
    title = obj["title"]

    "httpx #{url}" <>
      if(status, do: " [#{status}]", else: "") <> if(title, do: " #{title}", else: "")
  end

  # ── subfinder ───────────────────────────────────────────────────────────

  defp parse_subfinder(payload) do
    payload
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn domain ->
      host =
        case Jason.decode(domain) do
          {:ok, %{"host" => h}} -> h
          _ -> domain
        end

      %{
        category: :finding,
        content: "subdomain",
        target: host,
        source: "subfinder",
        confidence: :medium,
        metadata: %{}
      }
    end)
  end

  # ── nuclei JSONL ────────────────────────────────────────────────────────

  defp parse_nuclei(payload) do
    payload
    |> json_lines()
    |> Enum.map(fn obj ->
      info = obj["info"] || %{}
      class = info["classification"] || %{}
      template = obj["template-id"] || obj["templateID"] || obj["template_id"] || "nuclei"
      severity = info["severity"] || obj["severity"] || "info"
      matched = obj["matched-at"] || obj["matched-at"] || obj["host"] || obj["url"] || ""
      cve = first_cve(class["cve-id"] || class["cve_id"] || info["cve"])

      %{
        category: :vulnerability,
        content: info["name"] || template,
        target: matched,
        source: "nuclei",
        cve: cve,
        weaknesses: [%{id: template}],
        confidence: nuclei_confidence(severity),
        metadata: %{"template" => template, "severity" => severity}
      }
    end)
    |> Enum.reject(&(&1.target in [nil, ""]))
  end

  defp first_cve(list) when is_list(list), do: Enum.find(list, &is_binary/1)
  defp first_cve(cve) when is_binary(cve) and cve != "", do: cve
  defp first_cve(_), do: nil

  defp nuclei_confidence(sev) when is_binary(sev) do
    case String.downcase(sev) do
      "critical" -> :high
      "high" -> :high
      "medium" -> :medium
      _ -> :low
    end
  end

  defp nuclei_confidence(_), do: :medium

  # ── naabu JSONL ─────────────────────────────────────────────────────────

  defp parse_naabu(payload) do
    payload
    |> json_lines()
    |> Enum.map(fn obj ->
      host = obj["host"] || obj["ip"] || ""
      port = obj["port"]
      proto = obj["protocol"] || "tcp"

      %{
        category: :finding,
        content: "naabu #{host}:#{port}/#{proto}",
        target: host,
        source: "naabu",
        port: port && to_string(port),
        services:
          if(is_integer(port),
            do: [%{port: port, protocol: proto, product: "", version: ""}],
            else: []
          ),
        confidence: :medium,
        metadata: %{}
      }
    end)
    |> Enum.reject(&(&1.target in [nil, ""]))
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp json_lines(payload) do
    payload
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = obj} -> [obj]
        {:ok, list} when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end
    end)
  end

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  defp host_of(_), do: ""

  defp path_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> "/"
    end
  end

  defp path_of(_), do: "/"
end
