defmodule OptimalSystemAgent.Security.VariantAnalysis do
  @moduledoc """
  Hunt structurally similar unpatched sites given a known bug, patch, or CVE.

  Variant analysis is the highest-yield 0-day mode: a seed pattern is far
  more tractable than open-ended hunting. This module is source search, not
  exploit generation - it returns file:line hits with the fingerprint that
  matched.
  """

  @default_exts ~w(.ex .exs .py .js .ts .tsx .rb .go .php .java .rs .c .cpp .jsx)

  @skip_dirs MapSet.new(~w(.git _build deps node_modules priv/static .elixir_ls cover))

  @sink_fingerprints [
    "os.system",
    "os.popen",
    "subprocess",
    "eval(",
    "exec(",
    "innerHTML",
    "document.write",
    "cursor.execute",
    "rawQuery",
    "Ecto.Adapters.SQL.query",
    ":erlang.binary_to_term",
    "Marshal.load",
    "pickle.loads",
    "yaml.load(",
    "unserialize(",
    "send_file",
    "File.read",
    "open(",
    "render_template_string",
    "Runtime.getRuntime().exec"
  ]

  @type hit :: %{
          path: String.t(),
          line: pos_integer(),
          snippet: String.t(),
          reason: String.t(),
          fingerprint: String.t()
        }

  @doc """
  Scan a repo for variants.

  Requires `:root` and one of `:pattern` (Regex or string) or `:needle` (source
  snippet from which sink fingerprints are extracted).
  """
  @spec scan(keyword()) :: {:ok, [hit()]} | {:error, String.t()}
  def scan(opts) do
    root = Keyword.get(opts, :root)

    cond do
      not is_binary(root) ->
        {:error, "root is required"}

      not File.dir?(root) ->
        {:error, "root not found: #{root}"}

      true ->
        regexes = compile_needles(opts)
        exts = MapSet.new(Keyword.get(opts, :glob, @default_exts))
        max_hits = Keyword.get(opts, :max_hits, 50)
        hits = walk(root, root, regexes, exts, [], max_hits)
        {:ok, hits}
    end
  end

  @doc "Extract sink fingerprints from a CVE/patch description."
  @spec from_cve_description(String.t()) :: [String.t()]
  def from_cve_description(text) when is_binary(text) do
    lower = String.downcase(text)

    @sink_fingerprints
    |> Enum.filter(&String.contains?(lower, String.downcase(&1)))
    |> Enum.uniq()
  end

  def from_cve_description(_), do: []

  defp compile_needles(opts) do
    cond do
      match?(%Regex{}, Keyword.get(opts, :pattern)) ->
        [{Keyword.get(opts, :pattern), inspect(Keyword.get(opts, :pattern))}]

      is_binary(Keyword.get(opts, :pattern)) ->
        pat = Keyword.get(opts, :pattern)

        regex =
          if Keyword.get(opts, :regex, false) do
            Regex.compile!(pat, "i")
          else
            Regex.compile!(Regex.escape(pat), "i")
          end

        [{regex, pat}]

      is_binary(Keyword.get(opts, :needle)) ->
        fps = fingerprints_from_needle(Keyword.get(opts, :needle))
        Enum.map(fps, fn fp -> {Regex.compile!(Regex.escape(fp), "i"), fp} end)

      true ->
        []
    end
  end

  defp fingerprints_from_needle(needle) do
    found = Enum.filter(@sink_fingerprints, &String.contains?(needle, &1))
    if found == [], do: @sink_fingerprints, else: found
  end

  defp walk(_root, _dir, [], _exts, acc, _max), do: acc

  defp walk(_root, _dir, _regexes, _exts, acc, max) when length(acc) >= max, do: acc

  defp walk(root, dir, regexes, exts, acc, max) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, a ->
          if length(a) >= max do
            a
          else
            path = Path.join(dir, name)
            rel = Path.relative_to(path, root)

            cond do
              skip?(name, rel) ->
                a

              File.dir?(path) ->
                walk(root, path, regexes, exts, a, max)

              File.regular?(path) and MapSet.member?(exts, Path.extname(path)) ->
                scan_file(path, rel, regexes, a, max)

              true ->
                a
            end
          end
        end)

      _ ->
        acc
    end
  end

  defp skip?(name, rel) do
    MapSet.member?(@skip_dirs, name) or
      Enum.any?(@skip_dirs, &String.starts_with?(rel, &1 <> "/"))
  end

  defp scan_file(path, rel, regexes, acc, max) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(["\n", "\r\n"], trim: false)
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {line, n}, a ->
          if length(a) >= max do
            a
          else
            case Enum.find(regexes, fn {re, _} -> Regex.match?(re, line) end) do
              {_, fp} ->
                a ++
                  [
                    %{
                      path: rel,
                      line: n,
                      snippet: String.trim(line),
                      reason: "matched fingerprint",
                      fingerprint: fp
                    }
                  ]

              nil ->
                a
            end
          end
        end)

      _ ->
        acc
    end
  end
end
