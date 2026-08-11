defmodule OptimalSystemAgent.Verify.PostEdit do
  @moduledoc """
  Post-edit **format + diagnostics** loop — the "don't edit blind" feedback path
  (gap analysis G1 + G2).

  Wired as the `:diagnostics_provider` (see `config/config.exs`), this module runs
  after every `file_edit` / `multi_file_edit` / `file_write` / `file_create` on the
  touched file. `OptimalSystemAgent.Agent.Reminders.collect_diagnostics/2` calls
  `run/2` and, when it returns a non-empty summary, injects
  `"Diagnostics for <path>:\\n<summary>"` back into the model's context the SAME turn
  — so the model sees the syntax/parse error it just made instead of discovering it
  20 tool-calls later.

  Two things happen per supported file, keyed by extension:

    * **G2 — auto-format in place** (best-effort, silent). Elixir formats in-process
      via `Code.format_string!/2` (respecting `.formatter.exs` opts) — no `mix`
      startup cost. Other languages use their single-file formatter
      (`gofmt -w`, `rustfmt`, `prettier --write`, `ruff format`).
    * **G1 — fast diagnostics** (surfaced). Single-file syntax/parse check whose
      errors are returned to the caller: Elixir via `Code.string_to_quoted/2`
      (in-process, instant), Go via `gofmt -e`, Rust via `rustfmt`, JS via
      `node --check`, Python via `ruff check` / `py_compile`. TS/TSX parse errors
      surface through `prettier`.

  This is intentionally a **fast, dependency-light, single-file** loop rather than a
  long-running language-server. It catches the overwhelmingly common blind-edit
  failure (a syntax/parse mistake) and keeps every file formatted, degrading
  gracefully to a no-op when a tool binary is not installed. Cross-file semantic
  diagnostics (undefined symbols, type errors) are a heavier follow-up that can slot
  into the same seam per language.

  ## Safety

    * Never raises into the caller — every path is guarded; on any error it returns
      `""` (the edit already landed; diagnostics are advisory).
    * Formatting only ever WRITES a file it could successfully format; a file with a
      syntax error is left byte-for-byte untouched and its error is reported instead.
    * Each external command is time-boxed and skipped entirely if its binary is
      absent (`System.find_executable/1`).

  ## Testing seam

  `analyze/2` is the pure-ish core and takes an injected `exec` function
  (`(program, args, cwd) -> {output, exit_code}`), so tests exercise the language
  routing and diagnostic extraction without shelling out. In-process Elixir handling
  uses real temp files.
  """

  require Logger

  @default_timeout_ms 8_000

  # extension → language bucket
  @ext_lang %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".go" => :go,
    ".rs" => :rust,
    ".js" => :js,
    ".jsx" => :js,
    ".mjs" => :js,
    ".cjs" => :js,
    ".ts" => :ts,
    ".tsx" => :ts,
    ".py" => :python,
    ".json" => :json
  }

  # Elixir .formatter.exs keys safe to forward to Code.format_string!/2 (no
  # plugins / imports / input globs).
  @formatter_opt_keys [
    :line_length,
    :locals_without_parens,
    :force_do_end_blocks,
    :normalize_bitstring_modifiers,
    :normalize_charlists_as_sigils
  ]

  @doc """
  Provider entrypoint (`{#{inspect(__MODULE__)}, :run}`). Returns a diagnostics
  summary string, or `""` when the feature is disabled, the file type is
  unsupported, or the file is clean. Never raises.
  """
  @spec run(String.t(), map()) :: String.t()
  def run(path, state \\ %{}) do
    if enabled?() and is_binary(path) and File.regular?(path) do
      analyze(path, resolve_exec(state))
    else
      ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  @doc """
  Pure core: format (side effect) + diagnostics for one file using the given
  `exec` runner. Exposed for tests. Returns the diagnostics summary (`""` if clean
  / unsupported).
  """
  @spec analyze(String.t(), (String.t(), [String.t()], String.t() -> {term(), term()})) ::
          String.t()
  def analyze(path, exec) when is_binary(path) and is_function(exec, 3) do
    case lang_for(path) do
      nil -> ""
      lang -> lang |> check(path, exec) |> clamp()
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  @doc "Language bucket for a path by extension, or nil when unsupported."
  @spec lang_for(String.t()) :: atom() | nil
  def lang_for(path) when is_binary(path) do
    Map.get(@ext_lang, path |> Path.extname() |> String.downcase())
  end

  def lang_for(_), do: nil

  # ── config ─────────────────────────────────────────────────────────

  @doc false
  def enabled? do
    Application.get_env(:optimal_system_agent, :post_edit_verify, [])
    |> Keyword.get(:enabled, true)
  end

  defp timeout_ms do
    Application.get_env(:optimal_system_agent, :post_edit_verify, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  # ── per-language handling ──────────────────────────────────────────

  # Elixir: format in-process (fast), then syntax-check in-process. A file that
  # fails to format (syntax error) is left untouched and its error is reported.
  defp check(:elixir, path, _exec) do
    format_elixir(path)
    elixir_syntax(path)
  end

  # Go: `gofmt -e -w` formats in place AND reports parse errors on non-zero exit
  # (writing nothing when the source doesn't parse).
  defp check(:go, path, exec) do
    case exec.("gofmt", ["-e", "-w", path], dir(path)) do
      {out, code} when is_integer(code) and code != 0 -> to_string(out)
      _ -> ""
    end
  end

  # Rust: rustfmt formats in place; parse errors go to stderr with a non-zero exit.
  defp check(:rust, path, exec) do
    case exec.("rustfmt", ["--edition", "2021", path], dir(path)) do
      {out, code} when is_integer(code) and code != 0 -> to_string(out)
      _ -> ""
    end
  end

  # JS: prettier --write (format + parse-error) then node --check (syntax).
  defp check(:js, path, exec) do
    first_nonempty([prettier(path, exec), node_check(path, exec)])
  end

  # TS/TSX: prettier is the fast parse check (no cheap single-file typecheck).
  defp check(:ts, path, exec) do
    prettier(path, exec)
  end

  # JSON: prettier --write; parse errors surface on non-zero exit.
  defp check(:json, path, exec) do
    prettier(path, exec)
  end

  # Python: ruff format (best-effort) + ruff check; fall back to py_compile when
  # ruff isn't installed.
  defp check(:python, path, exec) do
    _ = exec.("ruff", ["format", path], dir(path))

    case exec.("ruff", ["check", "--quiet", path], dir(path)) do
      {out, code} when is_integer(code) and code != 0 -> to_string(out)
      {:__missing__, _} -> py_compile(path, exec)
      _ -> ""
    end
  end

  defp check(_other, _path, _exec), do: ""

  # ── shared external-tool helpers ───────────────────────────────────

  defp prettier(path, exec) do
    case exec.("prettier", ["--write", path], dir(path)) do
      {out, code} when is_integer(code) and code != 0 -> to_string(out)
      _ -> ""
    end
  end

  defp node_check(path, exec) do
    if Path.extname(path) in [".js", ".mjs", ".cjs"] do
      case exec.("node", ["--check", path], dir(path)) do
        {out, code} when is_integer(code) and code != 0 -> to_string(out)
        _ -> ""
      end
    else
      ""
    end
  end

  defp py_compile(path, exec) do
    case exec.("python3", ["-m", "py_compile", path], dir(path)) do
      {out, code} when is_integer(code) and code != 0 -> to_string(out)
      _ -> ""
    end
  end

  # ── Elixir in-process format + syntax ──────────────────────────────

  defp format_elixir(path) do
    with {:ok, src} <- File.read(path),
         formatted when is_binary(formatted) <- try_format(src, path) do
      # Only rewrite when formatting actually changed something, and never when
      # it would empty the file.
      if formatted != "" and formatted != src do
        # Formatting is not instantaneous (it parses the file and walks up to
        # 40 parent directories looking for .formatter.exs), so the bytes on
        # disk can have moved on since `src` was read — by the user's editor,
        # or by another agent. Writing `formatted` unconditionally would
        # silently revert whatever landed in that window. Re-read and only
        # write when the file is still byte-identical to what was formatted.
        if File.read(path) == {:ok, src} do
          case File.write(path, formatted) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.debug("[PostEdit] format write failed for #{path}: #{inspect(reason)}")
          end
        end
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp try_format(src, path) do
    opts = elixir_formatter_opts(path)
    (Code.format_string!(src, opts) |> IO.iodata_to_binary()) <> "\n"
  rescue
    # SyntaxError / TokenMissingError on invalid source → skip formatting, leave
    # the file untouched so elixir_syntax/1 can report the error.
    _ -> nil
  end

  # Read formatting options out of the nearest `.formatter.exs` WITHOUT
  # executing it.
  #
  # This used to be `Code.eval_file(file)`. `.formatter.exs` is arbitrary
  # Elixir source belonging to whatever repository happens to be on disk, and
  # this function runs on EVERY file_edit / multi_file_edit / file_write (see
  # the `:diagnostics_provider` wiring in config/config.exs and
  # `Agent.Reminders`). Evaluating it meant that editing a single file inside
  # any cloned repository executed that repository's code inside the agent's
  # BEAM, with the agent's full filesystem and network access — remote code
  # execution triggered by nothing more than `git clone` plus one edit. The
  # `rescue` below made it silent.
  #
  # Parsing is enough. A `.formatter.exs` evaluates to a keyword list, so the
  # options we care about are literals in the AST and can be read straight off
  # it. Anything computed (`Path.wildcard/1`, `import_deps`, plugins) is simply
  # not literal, so it is dropped rather than run — which is the correct
  # outcome anyway, since @formatter_opt_keys already excludes those keys.
  defp elixir_formatter_opts(path) do
    with file when is_binary(file) <- find_up(dir(path), ".formatter.exs"),
         {:ok, src} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(src),
         opts when is_list(opts) <- literal_keyword(ast) do
      Keyword.take(opts, @formatter_opt_keys)
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Convert a quoted top-level keyword list into a real keyword list, keeping
  # only pairs whose value is a pure literal. Never evaluates.
  defp literal_keyword(ast) when is_list(ast) do
    Enum.reduce(ast, [], fn
      {key, value}, acc when is_atom(key) ->
        if Macro.quoted_literal?(value), do: [{key, unquote_literal(value)} | acc], else: acc

      _, acc ->
        acc
    end)
  end

  defp literal_keyword(_), do: nil

  # A quoted literal is already its own value for scalars and lists; 2-tuples
  # need their elements walked. `Macro.quoted_literal?/1` guarantees no calls
  # are present, so this is a pure structural rewrite with nothing to execute.
  defp unquote_literal(list) when is_list(list), do: Enum.map(list, &unquote_literal/1)
  defp unquote_literal({a, b}), do: {unquote_literal(a), unquote_literal(b)}
  defp unquote_literal(other), do: other

  defp elixir_syntax(path) do
    with {:ok, src} <- File.read(path),
         {:error, {loc, desc, token}} <- Code.string_to_quoted(src, file: path) do
      "#{rel(path)}:#{loc_line(loc)}: #{describe(desc)}#{describe(token)}" |> String.trim()
    else
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  defp loc_line(loc) when is_list(loc), do: Keyword.get(loc, :line, 0)
  defp loc_line(loc) when is_integer(loc), do: loc
  defp loc_line(_), do: 0

  defp describe({a, b}), do: to_string(a) <> to_string(b)
  defp describe(term) when is_binary(term), do: term
  defp describe(term), do: to_string(term)

  # ── misc helpers ───────────────────────────────────────────────────

  defp resolve_exec(state) do
    case Map.get(state, :cmd_fun) do
      fun when is_function(fun, 3) -> fun
      _ -> &default_exec/3
    end
  end

  # Run an external command with a timeout, capturing stdout+stderr. Returns
  # `{:__missing__, program}` when the binary isn't on PATH so callers can skip
  # cleanly, or `{"", :timeout}` when it overruns.
  defp default_exec(program, args, cwd) do
    if System.find_executable(program) do
      task =
        Task.async(fn ->
          try do
            System.cmd(program, args, cd: cwd, stderr_to_stdout: true)
          rescue
            _ -> {"", 1}
          catch
            _, _ -> {"", 1}
          end
        end)

      case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, code}} -> {to_string(out), code}
        _ -> {"", :timeout}
      end
    else
      {:__missing__, program}
    end
  end

  defp first_nonempty(list) do
    Enum.find(list, "", &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp clamp(text) when is_binary(text) do
    case String.trim(text) do
      "" -> ""
      trimmed -> String.slice(trimmed, 0, 1500)
    end
  end

  defp clamp(_), do: ""

  defp dir(path), do: Path.dirname(path)

  defp rel(path) do
    try do
      Path.relative_to_cwd(path)
    rescue
      _ -> path
    end
  end

  # Walk up from `start_dir` looking for `name`; nil if not found before root.
  defp find_up(start_dir, name) do
    start_dir = Path.expand(start_dir)
    do_find_up(start_dir, name, 0)
  end

  defp do_find_up(_dir, _name, depth) when depth > 40, do: nil

  defp do_find_up(dir, name, depth) do
    candidate = Path.join(dir, name)

    cond do
      File.regular?(candidate) -> candidate
      dir == Path.dirname(dir) -> nil
      true -> do_find_up(Path.dirname(dir), name, depth + 1)
    end
  end
end
