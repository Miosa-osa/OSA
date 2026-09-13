defmodule OptimalSystemAgent.Security.CiScan do
  @moduledoc """
  Headless continuous-scan mode for CI.

  Discovers likely entry files, runs an injectable whitebox analyzer (never
  a live LLM unless the caller passed a runner), falls back to a cheap static
  sink scan, and emits SARIF plus a fail-on-severity verdict. No packets
  leave the machine.

  Diff-scope (`:since` / `:changed_files`) limits discovery to files changed
  since a git ref. Changed source files are scanned even when they are not
  request handlers. Git failure fails closed: `discover_entries/2` returns
  `[]`, `run/1` returns `{:error, reason}`.
  """

  alias OptimalSystemAgent.Security.CallChainAnalyzer

  @entry_names ~w(router.ex router.go app.py application.py main.py index.js index.ts server.js server.ts app.js app.ts main.go main.rs Application.java routes.rb urls.py)

  # Seed on files that *handle requests*, not files named app.py.
  @handler_re ~r{@(app|router|get|post|put|patch|delete)\.|APIRouter|FastAPI|flask\.Flask|express\(\)|chi\.NewRouter|http\.HandleFunc|gin\.(Default|New)|mux\.NewRouter|plug :match|ActionController|createServer\(}i

  @sink_re ~r/os\.system|subprocess|eval\(|exec\(|innerHTML|document\.write|cursor\.execute|pickle\.loads|yaml\.load\(|unserialize\(|render_template_string|Runtime\.getRuntime\(\)\.exec|:erlang\.binary_to_term/i

  @source_exts MapSet.new(~w(.ex .exs .py .js .ts .tsx .rb .go .java .rs .php))

  @doc """
  Find likely HTTP/app entry files under `root`.

  Options:
    * `:max` - cap (default 40)
    * `:changed_files` - explicit relative or absolute paths (takes precedence over `:since`)
    * `:since` - git ref (`HEAD~1`, `origin/main`, ...)
    * `:git` - injectable `(root, args) -> {:ok, stdout} | {:error, reason}`
  """
  @spec discover_entries(String.t(), keyword()) :: [String.t()]
  def discover_entries(root, opts \\ []) when is_binary(root) do
    max = Keyword.get(opts, :max, 40)

    cond do
      not File.dir?(root) ->
        []

      is_list(Keyword.get(opts, :changed_files)) ->
        entries_from_changed(root, Keyword.fetch!(opts, :changed_files), max)

      is_binary(Keyword.get(opts, :since)) ->
        case git_changed_files(root, opts) do
          {:ok, files} -> entries_from_changed(root, files, max)
          {:error, _} -> []
        end

      true ->
        discover_all(root, max)
    end
  end

  @doc """
  Run a CI scan.

  Options: `:root` (required), `:analyzer`, `:runner`, `:reader`, `:fail_on`,
  `:max`, `:since`, `:changed_files`, `:git`.
  If no analyzer/runner is supplied, only discovery + static sink scan run.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) do
    root = Keyword.get(opts, :root)

    if not is_binary(root) or not File.dir?(root) do
      {:error, "root is required and must exist"}
    else
      case discover_for_run(root, opts) do
        {:error, reason} ->
          {:error, git_error_message(reason)}

        {:ok, entries} ->
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

          summary = summarize(findings, opts, entries)
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

  @doc false
  @spec handler_file?(String.t()) :: boolean()
  def handler_file?(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) < 200_000 -> Regex.match?(@handler_re, content)
      _ -> false
    end
  end

  def handler_file?(_), do: false

  defp discover_for_run(root, opts) do
    discover_opts = Keyword.take(opts, [:max, :since, :changed_files, :git])

    cond do
      is_list(Keyword.get(opts, :changed_files)) ->
        {:ok, discover_entries(root, discover_opts)}

      is_binary(Keyword.get(opts, :since)) ->
        case git_changed_files(root, opts) do
          {:ok, files} ->
            {:ok, discover_entries(root, Keyword.put(discover_opts, :changed_files, files))}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:ok, discover_entries(root, discover_opts)}
    end
  end

  defp discover_all(root, max) do
    root
    |> Path.join("**/*.{ex,exs,py,js,ts,tsx,rb,go,java,rs,php}")
    |> Path.wildcard()
    |> Enum.filter(&entry_file?/1)
    |> Enum.sort()
    |> Enum.take(max)
  end

  defp entries_from_changed(root, rels, max) do
    root = Path.expand(root)

    rels
    |> Enum.map(&normalize_changed(root, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&source_file?/1)
    |> Enum.sort_by(fn path ->
      {if(entry_file?(path), do: 0, else: 1), path}
    end)
    |> Enum.take(max)
  end

  defp normalize_changed(_root, path) when not is_binary(path), do: nil

  defp normalize_changed(root, path) do
    trimmed =
      path
      |> String.trim()
      |> String.replace("\\", "/")
      |> String.replace_prefix("./", "")

    abs =
      if Path.type(trimmed) == :absolute do
        Path.expand(trimmed)
      else
        Path.expand(trimmed, root)
      end

    if under_root?(root, abs), do: abs, else: nil
  end

  defp under_root?(root, path) do
    prefix = String.trim_trailing(root, "/") <> "/"
    path == root or String.starts_with?(path, prefix)
  end

  defp source_file?(path), do: MapSet.member?(@source_exts, Path.extname(path))

  defp git_changed_files(root, opts) do
    since = Keyword.fetch!(opts, :since)
    git_fn = Keyword.get(opts, :git, &default_git/2)

    case git_fn.(root, ["diff", "--name-only", "--diff-filter=ACMR", since]) do
      {:ok, stdout} -> {:ok, parse_name_only(stdout)}
      {:error, reason} -> {:error, reason}
      other -> {:error, "git failed: #{inspect(other)}"}
    end
  end

  defp default_git(root, args) do
    # Route through the hardened wrapper, never raw System.cmd/3 — a CI scan
    # runs against an untrusted checkout, exactly the case the wrapper's
    # `-c` overrides (no ext-diff / textconv / filter drivers) defend against.
    case OptimalSystemAgent.Git.cmd(args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "git exited #{status}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_name_only(stdout) when is_binary(stdout) do
    stdout
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_name_only(other), do: parse_name_only(to_string(other))

  defp git_error_message(reason) when is_binary(reason), do: reason
  defp git_error_message(reason), do: inspect(reason)

  defp entry_file?(path) do
    base = Path.basename(path)

    cond do
      base in @entry_names -> true
      String.contains?(base, "router") -> true
      String.contains?(base, "controller") -> true
      true -> handler_file?(path)
    end
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

  defp summarize(findings, opts, entries) do
    counts =
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

    Map.merge(counts, %{
      diff_scope: diff_scope?(opts),
      files_considered: length(entries)
    })
  end

  defp diff_scope?(opts) do
    is_list(Keyword.get(opts, :changed_files)) or is_binary(Keyword.get(opts, :since))
  end

  defp sarif_level(:critical), do: "error"
  defp sarif_level(:high), do: "error"
  defp sarif_level(:medium), do: "warning"
  defp sarif_level(:low), do: "note"
  defp sarif_level(_), do: "warning"
end
