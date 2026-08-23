defmodule OptimalSystemAgent.Security.CiScan do
  @moduledoc """
  Headless continuous-scan mode for CI.

  Discovers likely entry files, runs an injectable whitebox analyzer (never
  a live LLM unless the caller passed a runner), falls back to a cheap static
  sink scan, and emits SARIF plus a fail-on-severity verdict. No packets
  leave the machine.
  """

  alias OptimalSystemAgent.Security.CallChainAnalyzer

  @entry_names ~w(router.ex router.go app.py application.py main.py index.js index.ts server.js server.ts app.js app.ts main.go main.rs Application.java routes.rb urls.py)

  @sink_re ~r/os\.system|subprocess|eval\(|exec\(|innerHTML|document\.write|cursor\.execute|pickle\.loads|yaml\.load\(|unserialize\(|render_template_string|Runtime\.getRuntime\(\)\.exec|:erlang\.binary_to_term/i

  @doc "Find likely HTTP/app entry files under `root`."
  @spec discover_entries(String.t(), keyword()) :: [String.t()]
  def discover_entries(root, opts \\ []) when is_binary(root) do
    max = Keyword.get(opts, :max, 40)

    if File.dir?(root) do
      root
      |> Path.join("**/*.{ex,exs,py,js,ts,tsx,rb,go,java,rs,php}")
      |> Path.wildcard()
      |> Enum.filter(&entry_file?/1)
      |> Enum.sort()
      |> Enum.take(max)
    else
      []
    end
  end

  @doc """
  Run a CI scan.

  Options: `:root` (required), `:analyzer`, `:runner`, `:reader`, `:fail_on`.
  If no analyzer/runner is supplied, only discovery + static sink scan run.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) do
    root = Keyword.get(opts, :root)

    if not is_binary(root) or not File.dir?(root) do
      {:error, "root is required and must exist"}
    else
      entries = discover_entries(root)
      analyzer = Keyword.get(opts, :analyzer)
      fail_on = MapSet.new(Keyword.get(opts, :fail_on, [:critical, :high]))

      findings =
        cond do
          is_function(analyzer, 1) ->
            Enum.flat_map(entries, fn path ->
              content = File.read!(path)

              case analyzer.(
                     entry: Path.relative_to(path, root),
                     content: content,
                     reader: Keyword.get(opts, :reader),
                     runner: Keyword.get(opts, :runner)
                   ) do
                {:ok, list} when is_list(list) -> list
                _ -> []
              end
            end)

          Keyword.has_key?(opts, :runner) ->
            Enum.flat_map(entries, fn path ->
              content = File.read!(path)

              case CallChainAnalyzer.analyze(
                     entry: Path.relative_to(path, root),
                     content: content,
                     reader: Keyword.get(opts, :reader, fn _ -> :not_found end),
                     runner: Keyword.fetch!(opts, :runner)
                   ) do
                {:ok, list} -> list
                _ -> []
              end
            end)

          true ->
            static_hits(root, entries)
        end

      summary = summarize(findings)
      failed? = Enum.any?(findings, fn f -> Map.get(f, :severity) in fail_on end)

      {:ok,
       %{
         findings: findings,
         entries_scanned: length(entries),
         sarif: sarif_from_findings(findings),
         failed?: failed?,
         summary: summary
       }}
    end
  end

  @doc "Minimal SARIF 2.1 document from analyzer findings."
  @spec sarif_from_findings([map()]) :: map()
  def sarif_from_findings(findings) when is_list(findings) do
    results =
      Enum.map(findings, fn f ->
        class = to_string(Map.get(f, :vuln_class) || "finding")
        sev = Map.get(f, :severity) || :medium

        %{
          "ruleId" => class,
          "level" => sarif_level(sev),
          "message" => %{"text" => Map.get(f, :reasoning) || Map.get(f, :snippet) || class},
          "locations" => [
            %{
              "physicalLocation" => %{
                "artifactLocation" => %{
                  "uri" => Map.get(f, :source) || Map.get(f, :path) || "unknown"
                },
                "region" => %{"startLine" => Map.get(f, :line) || 1}
              }
            }
          ]
        }
      end)

    %{
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{"name" => "OSA", "informationUri" => "https://github.com/Miosa-osa/OSA"}
          },
          "results" => results
        }
      ]
    }
  end

  def sarif_from_findings(_), do: sarif_from_findings([])

  defp entry_file?(path) do
    base = Path.basename(path)

    base in @entry_names or String.contains?(base, "router") or
      String.contains?(base, "controller")
  end

  defp static_hits(root, entries) do
    Enum.flat_map(entries, fn path ->
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split(["\n", "\r\n"], trim: false)
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, n} ->
            if Regex.match?(@sink_re, line) do
              [
                %{
                  vuln_class: :rce,
                  exploitable: false,
                  confidence: :low,
                  source: Path.relative_to(path, root),
                  sink: String.trim(line),
                  call_chain: [Path.relative_to(path, root)],
                  reasoning: "static sink hit (unconfirmed)",
                  poc: "",
                  cvss_vector: nil,
                  cvss_score: nil,
                  severity: :medium,
                  path: Path.relative_to(path, root),
                  line: n,
                  snippet: String.trim(line)
                }
              ]
            else
              []
            end
          end)

        _ ->
          []
      end
    end)
  end

  defp summarize(findings) do
    Enum.reduce(findings, %{critical: 0, high: 0, medium: 0, low: 0}, fn f, acc ->
      key =
        case Map.get(f, :severity) do
          :critical -> :critical
          :high -> :high
          :low -> :low
          _ -> :medium
        end

      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp sarif_level(:critical), do: "error"
  defp sarif_level(:high), do: "error"
  defp sarif_level(:medium), do: "warning"
  defp sarif_level(:low), do: "note"
  defp sarif_level(_), do: "warning"
end
