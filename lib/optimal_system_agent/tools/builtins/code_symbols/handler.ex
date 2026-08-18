defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `code_symbols`.

    * `validate/2`          — type checks input shape
    * `check_permissions/2` — path allowlist check
    * `execute/2`           — outline a source file, or return one definition

  ## Why this returns bodies now

  Measured over 118 SWE-bench / SWE-bench-Pro transcripts: **312 of 868
  `file_grep` calls are immediately followed by a `file_read`**. The pattern is
  always the same — grep to find where a definition lives, then read a window
  around it to see what it says. The grep result is cheap (median 238 bytes);
  the read that follows is not, and it returns a fixed window that either
  overshoots the definition or clips it, which is one source of the 154 reads
  classified as *"around line N"*.

  `name` collapses that pair. One call, and the result is the definition and
  nothing else — no surrounding function, no guessed window. This is the 80% of
  a language server's *go to definition* that needs no language server, no
  index, and no binary in the task image, which matters because a census of all
  89 Terminal-Bench 2.1 images found **zero** with ctags, tree-sitter, ripgrep,
  or any LSP. See `docs/design/symbol-resolution.md`.

  ## What the body extraction is, exactly

  A heuristic, and deliberately one: the definition line, plus every following
  line indented deeper than it, plus the closing lines at its own indentation
  (`}`, `end`, `)`). That rule is language-agnostic and it is right for
  brace languages and for indentation languages alike. It is wrong for
  one-line-per-brace styles that outdent a closer past the definition, and for
  definitions that continue on a line indented *less* than the header. Both are
  visible in the result — the line range is always reported — rather than
  silent.
  """

  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path) do
    case Map.get(input, "name") do
      nil -> {:ok, input}
      n when is_binary(n) -> {:ok, input}
      other -> {:error, "name must be a string, got #{inspect(other)}", -32_602}
    end
  end

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

    case File.read(expanded) do
      {:ok, content} ->
        ext = expanded |> Path.extname() |> String.downcase()
        symbols = extract_symbols(content, ext)

        case params["name"] do
          n when is_binary(n) and n != "" ->
            definitions(path, content, symbols, n)

          _ ->
            symbols |> filter_symbols(params["type"]) |> then(&format_result(path, &1))
        end

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, reason} ->
        {:error, "Error reading file: #{reason}"}
    end
  end

  # ── Private: one definition, not a window around it ───────────────────

  # Cap so a 900-line class body cannot arrive as a surprise. The cap is
  # reported when it bites, because a silently clipped definition is the
  # failure this whole path exists to remove.
  @max_body_lines 200

  defp definitions(path, content, symbols, wanted) do
    lines = String.split(content, "\n")

    case Enum.filter(symbols, fn {_l, _t, name} -> matches?(name, wanted) end) do
      [] ->
        known =
          symbols
          |> Enum.map(fn {_l, _t, n} -> n |> String.split(["/", " "]) |> hd() end)
          |> Enum.uniq()

        {:ok,
         "No symbol named #{inspect(wanted)} is DEFINED in #{path}. " <>
           near(known, wanted) <>
           "This tool finds definitions in one file; for uses of a name across the tree, " <>
           "search for it instead."}

      found ->
        {:ok,
         found
         |> Enum.take(5)
         |> Enum.map_join("\n\n", &render_body(path, lines, &1))}
    end
  end

  defp matches?(symbol_name, wanted) do
    base = symbol_name |> String.split(["/", " "]) |> hd()
    base == wanted
  end

  defp near([], _wanted), do: ""

  defp near(known, wanted) do
    close =
      known
      |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(wanted)))
      |> Enum.take(5)

    case close do
      [] -> "The file defines #{length(known)} symbol(s); omit `name` to list them. "
      hits -> "Closest names defined here: #{Enum.join(hits, ", ")}. "
    end
  end

  defp render_body(path, lines, {start_line, type, name}) do
    body = body_lines(lines, start_line)
    last = start_line + length(body) - 1

    clipped =
      if length(body) == @max_body_lines, do: " (clipped at #{@max_body_lines} lines)", else: ""

    "#{path}:#{start_line}-#{last}  [#{type}] #{name}#{clipped}\n" <>
      Enum.join(body, "\n")
  end

  # Two rules, and which one applies is decided by the source rather than by
  # the file extension, because brace style is a property of the code and not
  # of the language. If the definition opens a brace block — on its own line, as
  # Allman style does, or at the end of the header — the body ends when that
  # brace closes. Otherwise the body is what is indented deeper than the header,
  # which is the rule Python and Elixir need.
  defp body_lines(lines, start_line) do
    [head | rest] = Enum.drop(lines, start_line - 1)

    if brace_block?(head, rest) do
      [head | brace_body(rest, brace_delta(head))] |> Enum.take(@max_body_lines)
    else
      indent_body(head, rest)
    end
  end

  defp brace_block?(head, rest) do
    cond do
      brace_delta(head) > 0 -> true
      # Allman: the opener is the next non-blank line, at any indentation.
      true -> rest |> Enum.find(&(String.trim(&1) != "")) |> then(&(String.trim(&1 || "") == "{"))
    end
  end

  defp brace_delta(line) do
    length(:binary.matches(line, "{")) - length(:binary.matches(line, "}"))
  end

  defp brace_body(lines, depth) do
    lines
    |> Enum.reduce_while({[], depth}, fn line, {acc, d} ->
      d2 = d + brace_delta(line)

      cond do
        d2 <= 0 and d > 0 -> {:halt, {[line | acc], 0}}
        d2 <= 0 and String.trim(line) == "" -> {:cont, {[line | acc], d2}}
        d2 <= 0 and d == 0 and acc != [] -> {:halt, {acc, 0}}
        true -> {:cont, {[line | acc], d2}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> trim_trailing_blanks()
  end

  defp indent_body(head, rest) do
    base = indent_of(head)

    body =
      rest
      |> Enum.reduce_while([], fn line, acc ->
        cond do
          String.trim(line) == "" -> {:cont, [line | acc]}
          indent_of(line) > base -> {:cont, [line | acc]}
          closer?(line) -> {:cont, [line | acc]}
          true -> {:halt, acc}
        end
      end)
      |> Enum.reverse()
      |> trim_trailing_blanks()

    [head | body] |> Enum.take(@max_body_lines)
  end

  defp trim_trailing_blanks(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()
  end

  @closers ["}", "};", "}", ")", ");", "end", "end)", "})", "});", "]", "];", "}}", "*/"]
  defp closer?(line), do: String.trim(line) in @closers

  defp indent_of(line) do
    line
    |> String.replace("\t", "    ")
    |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))
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

  # C / C++ — 13 of the 89 Terminal-Bench 2.1 tasks are C or C++, and four of
  # the five tasks with more than 50 source files are, so this is where a
  # single-file outline has the most to look at. `gcc` is present in 29 of the
  # 89 images and `clangd` in none of them, which is why this is a regex and
  # not a compiler front end.
  defp extract_symbols(content, ext) when ext in ~w(.c .h .cc .cpp .cxx .hpp .hh) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        match = Regex.run(~r/^\s*(?:typedef\s+)?(?:struct|union|enum)\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "class", name}]

        match = Regex.run(~r/^\s*#\s*define\s+(\w+)/, line) ->
          [_ | [name]] = match
          [{line_num, "module", "#{name} (macro)"}]

        # A definition, not a declaration: the line must open a body or be the
        # header of one. A trailing `;` is a prototype and is skipped, and the
        # control keywords are excluded because `if (x) {` matches the same
        # shape as a function header.
        match = c_function(line) ->
          [{line_num, "function", match}]

        true ->
          []
      end
    end)
  end

  # Shell — every image in the benchmark is Debian-family, and 25 of 89 tasks
  # have no source language at all beyond shell.
  defp extract_symbols(content, ext) when ext in ~w(.sh .bash .zsh) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      case Regex.run(~r/^\s*(?:function\s+)?(\w[\w:.-]*)\s*\(\s*\)\s*\{?/, line) do
        [_ | [name]] -> [{line_num, "function", name}]
        _ -> []
      end
    end)
  end

  defp extract_symbols(_content, _ext), do: []

  @c_keywords ~w(if for while switch return else do case sizeof)

  defp c_function(line) do
    with [_, name] <- Regex.run(~r/^[A-Za-z_][\w\s\*&]*?\b(\w+)\s*\([^;]*$/, line),
         false <- name in @c_keywords,
         false <- String.trim(line) |> String.starts_with?(@c_keywords) do
      name
    else
      _ -> nil
    end
  end

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

  defp path_allowed?(expanded_path) do
    # Canonicalise before comparing - the roots are canonical, so an
    # unresolved path lands in the wrong namespace and /tmp is denied
    # on macOS. See PathPolicy.within_read_roots?/1.
    OptimalSystemAgent.Agent.Safety.PathPolicy.within_read_roots?(expanded_path)
  end
end
