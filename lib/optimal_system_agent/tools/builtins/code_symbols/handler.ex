defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `code_symbols`.

    * `validate/2`          — type checks input shape
    * `check_permissions/2` — path allowlist check
    * `execute/2`           — extract symbols from source file
  """

  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path), do: {:ok, input}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = Path.expand(path)

    if path_allowed?(expanded) do
      {:allow, input}
    else
      {:deny, "Access denied: #{path} is outside allowed paths"}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path} = params, _ctx) do
    expanded = Path.expand(path)
    filter_type = params["type"]

    case File.read(expanded) do
      {:ok, content} ->
        ext = expanded |> Path.extname() |> String.downcase()
        symbols = extract_symbols(content, ext)
        filtered = filter_symbols(symbols, filter_type)
        format_result(path, filtered)

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, reason} ->
        {:error, "Error reading file: #{reason}"}
    end
  end

  # ── Private: symbol extraction ────────────────────────────────────────

  defp extract_symbols(content, ext) when ext in [".ex", ".exs"] do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*defmodule\s+([\w.]+)/, line) ->
          [_ | [name]] = match
          [{line_num, "module", name}]

        match = Regex.run(~r/^\s*def\s+(\w+)[\s(]/, line) ->
          [_ | [name]] = match
          arity = extract_arity(line)
          [{line_num, "function", "#{name}/#{arity}"}]

        match = Regex.run(~r/^\s*defp\s+(\w+)[\s(]/, line) ->
          [_ | [name]] = match
          arity = extract_arity(line)
          [{line_num, "function", "#{name}/#{arity} (private)"}]

        match = Regex.run(~r/^\s*defmacro\s+(\w+)[\s(]/, line) ->
          [_ | [name]] = match
          arity = extract_arity(line)
          [{line_num, "function", "#{name}/#{arity} (macro)"}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ".py") do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*class\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", name}]

        match = Regex.run(~r/^\s*def\s+(\w+)\s*\(/, line) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        match = Regex.run(~r/^\s*async\s+def\s+(\w+)\s*\(/, line) ->
          [_ | [name]] = match
          [{line_num, "function", "#{name} (async)"}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ext) when ext in [".js", ".ts", ".jsx", ".tsx"] do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*class\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", name}]

        match = Regex.run(~r/^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*[\(<]/, line) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        match =
            Regex.run(
              ~r/^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?(?:function|\()/,
              line
            ) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        match = Regex.run(~r/^\s*export\s+(?:default\s+)?(?:const|function|class)\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "function", "#{name} (export)"}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ".go") do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*func\s+\((\w+\s+[\*\w]+)\)\s+(\w+)\s*\(/, line) ->
          [_ | [receiver, name]] = match
          [{line_num, "function", "#{name} (#{receiver})"}]

        match = Regex.run(~r/^\s*func\s+(\w+)\s*\(/, line) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        match = Regex.run(~r/^\s*type\s+(\w+)\s+struct\s*\{/, line) ->
          [_ | [name]] = match
          [{line_num, "class", "#{name} (struct)"}]

        match = Regex.run(~r/^\s*type\s+(\w+)\s+interface\s*\{/, line) ->
          [_ | [name]] = match
          [{line_num, "class", "#{name} (interface)"}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ".rs") do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*pub\s+fn\s+(\w+)\s*[\(<]/, line) ->
          [_ | [name]] = match
          [{line_num, "function", "#{name} (pub)"}]

        match = Regex.run(~r/^\s*fn\s+(\w+)\s*[\(<]/, line) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        match = Regex.run(~r/^\s*(?:pub\s+)?struct\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", "#{name} (struct)"}]

        match = Regex.run(~r/^\s*(?:pub\s+)?enum\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", "#{name} (enum)"}]

        match = Regex.run(~r/^\s*impl(?:<[^>]+>)?\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "module", "impl #{name}"}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ext) when ext in [".rb"] do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*class\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", name}]

        match = Regex.run(~r/^\s*module\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "module", name}]

        match = Regex.run(~r/^\s*def\s+(\w+[?!]?)/, line) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(content, ext) when ext in [".java", ".kt"] do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match =
            Regex.run(
              ~r/^\s*(?:public\s+|private\s+|protected\s+)?(?:abstract\s+|final\s+)?(?:class|interface|enum)\s+(\w+)/,
              line
            ) ->
          [_ | [name]] = match
          [{line_num, "class", name}]

        match =
            Regex.run(
              ~r/^\s*(?:public|private|protected|static|final|abstract|\s)+\s+\w+\s+(\w+)\s*\(/,
              line
            ) ->
          [_ | [name]] = match
          [{line_num, "function", name}]

        true ->
          []
      end
    end)
  end

  defp extract_symbols(_content, _ext), do: []

  # ── Private: helpers ──────────────────────────────────────────────────

  defp extract_arity(line) do
    case Regex.run(~r/\(([^)]*)\)/, line) do
      [_ | [args_str]] ->
        trimmed = String.trim(args_str)
        if trimmed == "", do: 0, else: trimmed |> String.split(",") |> length()

      _ ->
        0
    end
  end

  defp filter_symbols(symbols, nil), do: symbols
  defp filter_symbols(symbols, ""), do: symbols

  defp filter_symbols(symbols, type_filter) when is_binary(type_filter) do
    norm = String.downcase(type_filter)
    Enum.filter(symbols, fn {_line, type, _name} -> type == norm end)
  end

  defp format_result(path, []) do
    {:ok, "No symbols found in #{path}"}
  end

  defp format_result(path, symbols) do
    lines =
      Enum.map_join(symbols, "\n", fn {line_num, type, name} ->
        line_str = line_num |> Integer.to_string() |> String.pad_leading(4)
        "  L#{line_str}  [#{type}] #{name}"
      end)

    {:ok, "Symbols in #{path}:\n#{lines}"}
  end

  # Shared read allowlist — configured roots PLUS the session workspace. A
  # private copy here was blind to the session's `working_dir`.
  defp allowed_paths, do: OptimalSystemAgent.Agent.Safety.PathPolicy.read_roots()

  defp path_allowed?(expanded_path) do
    check_path =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn allowed ->
      String.starts_with?(check_path, allowed)
    end)
  end
end
