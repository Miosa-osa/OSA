defmodule OptimalSystemAgent.Security.SymbolResolver do
  @moduledoc """
  Jedi-lite symbol resolution via a pure Elixir file scan.

  No Jedi, no tree-sitter, no Mix deps, no network. `code_line` (the exact
  call-site text) disambiguates when the same name is defined in more than
  one file: files containing that line are searched first.

  Pass `reader: reader(root)` into `CallChainAnalyzer.analyze/1`. Parent may
  also accept an optional `:resolver` with the same contract; this module
  does not change the analyzer.
  """

  @default_max_files 400
  @default_exts ~w(.ex .exs .py .js .ts .rb .go .java .rs .php)
  @skip_dirs MapSet.new(~w(deps _build node_modules .git))
  @snippet_lines 30

  @type hit :: %{
          path: String.t(),
          snippet: String.t(),
          line: pos_integer(),
          kind: :definition | :call_site
        }

  @doc """
  Resolve `name` under a repo root.

  First argument is the symbol name (or the root when `:name` is set and
  `:root` is not). Options:

    * `:root` - directory to search (required)
    * `:name` - symbol name (required; defaults to the first argument)
    * `:code_line` - exact or substring of the call site (preferred)
    * `:max_files` - default 400
    * `:exts` - default `#{inspect(@default_exts)}`
  """
  @spec resolve(String.t(), keyword()) :: {:ok, hit()} | :not_found | {:error, String.t()}
  def resolve(first, opts \\ [])

  def resolve(first, opts) when is_binary(first) and is_list(opts) do
    {root, name} = root_and_name(first, opts)

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "name is required"}

      not is_binary(root) or String.trim(root) == "" ->
        {:error, "root is required"}

      not File.dir?(root) ->
        {:error, "root is required and must exist"}

      true ->
        do_resolve(Path.expand(root), String.trim(name), opts)
    end
  end

  def resolve(_, _), do: {:error, "name is required"}

  @doc """
  1-arity function suitable as `CallChainAnalyzer` `:reader`.

  Accepts `{:symbol, name, code_line}`, `{name, code_line}`, or `name`.
  Returns `{:ok, snippet}` or `:not_found`.
  """
  @spec reader(String.t()) :: (term() -> {:ok, String.t()} | :not_found)
  def reader(root) when is_binary(root) do
    fn arg ->
      case parse_reader_arg(arg) do
        {name, code_line} ->
          opts = [root: root, name: name]
          opts = if code_line, do: Keyword.put(opts, :code_line, code_line), else: opts

          case resolve(name, opts) do
            {:ok, %{snippet: snippet}} -> {:ok, snippet}
            _ -> :not_found
          end

        :error ->
          :not_found
      end
    end
  end

  # ── resolve ──────────────────────────────────────────────────────────────

  defp root_and_name(first, opts) do
    opt_root = Keyword.get(opts, :root)
    opt_name = Keyword.get(opts, :name)

    cond do
      present?(opt_root) and present?(opt_name) ->
        {opt_root, opt_name}

      present?(opt_root) ->
        {opt_root, first}

      present?(opt_name) ->
        {first, opt_name}

      true ->
        {opt_root, first}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp do_resolve(root, name, opts) do
    code_line = normalize_line(Keyword.get(opts, :code_line))
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    exts = Keyword.get(opts, :exts, @default_exts)
    pats = patterns(name)

    indexed =
      root
      |> list_source_files(exts, max_files)
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            lines = String.split(content, ["\n", "\r\n"], trim: false)
            [{rel_path(root, path), Path.extname(path), lines}]

          _ ->
            []
        end
      end)

    {preferred, rest} = partition_by_code_line(indexed, code_line)

    case find_definition(preferred ++ rest, pats) do
      {:ok, hit} ->
        {:ok, hit}

      :not_found when is_binary(code_line) ->
        find_call_site(preferred, pats, code_line)

      :not_found ->
        :not_found
    end
  end

  defp partition_by_code_line(indexed, nil), do: {[], indexed}

  defp partition_by_code_line(indexed, code_line) do
    Enum.split_with(indexed, fn {_path, _ext, lines} ->
      Enum.any?(lines, &line_contains?(&1, code_line))
    end)
  end

  defp find_definition(files, pats) do
    Enum.find_value(files, :not_found, fn {path, ext, lines} ->
      case find_line(lines, fn line -> definition?(line, ext, pats) end) do
        {_line, n} -> {:ok, build_hit(path, lines, n, :definition)}
        nil -> nil
      end
    end)
  end

  defp find_call_site(files, pats, code_line) do
    Enum.find_value(files, :not_found, fn {path, _ext, lines} ->
      case find_line(lines, fn line ->
             line_contains?(line, code_line) and call?(line, pats)
           end) do
        {_line, n} -> {:ok, build_hit(path, lines, n, :call_site)}
        nil -> nil
      end
    end)
  end

  defp find_line(lines, pred) do
    lines
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, n} ->
      if pred.(line), do: {line, n}, else: nil
    end)
  end

  defp build_hit(path, lines, n, kind) do
    %{path: path, snippet: snippet(lines, n), line: n, kind: kind}
  end

  defp snippet(lines, n) do
    total = length(lines)
    half = div(@snippet_lines, 2)
    from = max(1, n - half)
    to = min(total, from + @snippet_lines - 1)
    from = max(1, to - @snippet_lines + 1)

    lines
    |> Enum.slice((from - 1)..(to - 1)//1)
    |> Enum.join("\n")
  end

  defp line_contains?(line, code_line) do
    String.contains?(line, code_line) or
      String.contains?(String.trim(line), String.trim(code_line))
  end

  defp normalize_line(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_line(_), do: nil

  defp rel_path(root, path) do
    rel = Path.relative_to(path, root)
    if rel == path, do: path, else: rel
  end

  # ── heuristics ───────────────────────────────────────────────────────────

  defp patterns(name) do
    escaped = Regex.escape(name)

    %{
      elixir: Regex.compile!("(^|[^\\w.])defp?\\s+#{escaped}(\\s|\\(|,|$)"),
      python: Regex.compile!("^\\s*(async\\s+)?def\\s+#{escaped}\\s*\\("),
      function: Regex.compile!("\\bfunction\\s+#{escaped}\\s*\\("),
      const: Regex.compile!("\\b(const|let|var)\\s+#{escaped}\\s*="),
      method: Regex.compile!("^\\s*(async\\s+)?#{escaped}\\s*\\("),
      go: Regex.compile!("\\bfunc\\s+(\\([^)]*\\)\\s*)?#{escaped}\\s*\\("),
      generic: Regex.compile!("(def|function|func|fn)\\s+#{escaped}\\b"),
      call: Regex.compile!("\\b#{escaped}\\s*\\(")
    }
  end

  defp definition?(line, ext, pats) do
    specific =
      case ext do
        e when e in [".ex", ".exs"] ->
          Regex.match?(pats.elixir, line)

        ".py" ->
          Regex.match?(pats.python, line)

        e when e in [".js", ".ts"] ->
          Regex.match?(pats.function, line) or Regex.match?(pats.const, line) or
            Regex.match?(pats.method, line)

        ".go" ->
          Regex.match?(pats.go, line)

        _ ->
          false
      end

    specific or Regex.match?(pats.generic, line)
  end

  defp call?(line, pats), do: Regex.match?(pats.call, line)

  # ── files ────────────────────────────────────────────────────────────────

  defp list_source_files(root, exts, max_files) do
    extset = MapSet.new(exts)
    walk(root, root, extset, [], max_files) |> Enum.reverse()
  end

  defp walk(_root, _dir, _exts, acc, max) when length(acc) >= max, do: acc

  defp walk(root, dir, exts, acc, max) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, a ->
          if length(a) >= max do
            a
          else
            path = Path.join(dir, name)
            rel = Path.relative_to(path, root)

            cond do
              skip?(name, rel) ->
                a

              File.dir?(path) ->
                walk(root, path, exts, a, max)

              File.regular?(path) and MapSet.member?(exts, Path.extname(path)) ->
                [path | a]

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

  defp parse_reader_arg({:symbol, name, code_line}) when is_binary(name),
    do: {name, normalize_line(code_line)}

  defp parse_reader_arg({name, code_line}) when is_binary(name),
    do: {name, normalize_line(code_line)}

  defp parse_reader_arg(name) when is_binary(name), do: {name, nil}

  defp parse_reader_arg(_), do: :error
end
