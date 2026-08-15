defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_grep`.

  Behaviour split mirrors `FileRead.Handler`:
    * `validate/2`           — type-checks input shape (cheap)
    * `check_permissions/2`  — path allowlist + sensitive-file deny
    * `execute/2`            — ripgrep with Elixir fallback

  Logic relocated verbatim from the original `file_grep.ex`. No semantic
  changes — just relocation + permission/validation split.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"pattern" => pattern} = input, _ctx) when is_binary(pattern),
    do: {:ok, input}

  def validate(%{"pattern" => _}, _ctx),
    do: {:error, "pattern must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: pattern", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = Path.expand(path)

    cond do
      sensitive?(expanded) ->
        {:deny, "Access denied: #{path} is a sensitive system file"}

      not allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed paths"}

      true ->
        {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"pattern" => pattern} = params, _ctx) do
    # Expand against the SESSION's directory, not the OS process cwd.
    #
    # `Path.expand/1` resolves a relative path against `File.cwd!()`, which is
    # wherever the BACKEND booted — so a relative pattern was searched in the
    # daemon's own tree rather than the user's workspace. Measured on a
    # benchmark run AFTER the shell-side cwd fix: 29 tool results across three
    # runs reported `No files matched pattern
    # 'test/units/plugins/strategy/test_linear.py' under
    # /home/miosa/projects/osa/OSA`, affecting 7 of 12 instances.
    #
    # That failure is quiet and expensive: the agent asks for the file it needs,
    # is told it does not exist, and carries on without it.
    #
    # The earlier fix (786ac7b8) re-published the cwd across the Task boundary
    # so `shell_execute` saw it. It did not help here, because these tools never
    # consult the process dictionary at all — they call `Path.expand/1`, which
    # reads the OS cwd directly.
    path = Path.expand(params["path"] || ".", OptimalSystemAgent.Workspace.Cwd.get())

    if File.exists?(path) do
      do_search(pattern, path, params)
    else
      # A typo'd or stale path used to return "No matches found." — a silent
      # WRONG answer. The agent concludes the symbol does not exist anywhere and
      # follows a false trail, when in fact nothing was ever searched. ripgrep
      # exits 1 for "no match" AND for "path does not exist", and the fallback
      # simply globs an absent directory into []; neither could tell them apart.
      {:error, missing_path_message(params["path"] || ".", path)}
    end
  end

  def execute(_, _ctx), do: {:error, "Missing required parameter: pattern"}

  defp do_search(pattern, path, params) do
    rg_opts = %{
      glob: params["glob"],
      case_insensitive: params["case_insensitive"] == true,
      context_lines: params["context_lines"],
      output_mode: params["output_mode"],
      max_results: params["max_results"]
    }

    case try_ripgrep(pattern, path, rg_opts) do
      {:ok, output} -> {:ok, output |> bound_output() |> with_spread_trailer()}
      {:fallback, _} -> fallback_grep(pattern, path, rg_opts)
    end
  end

  # ── Private: missing-path diagnostics ─────────────────────────────────

  # Name what went wrong AND the next step: the nearest existing ancestor plus
  # the closest sibling names under it, so a one-character typo is a single
  # retry rather than a re-exploration of the tree.
  defp missing_path_message(display_path, expanded) do
    base =
      "Search path does not exist: #{display_path} (resolved to #{expanded}). " <>
        "Nothing was searched — this is NOT the same as 'no matches'. "

    base <> suggestion_sentence(expanded)
  end

  defp suggestion_sentence(expanded) do
    parent = Path.dirname(expanded)
    target = Path.basename(expanded)

    case nearest_existing(parent) do
      nil ->
        "Next step: verify the path with dir_list, or omit `path` to search the working directory."

      ^parent ->
        near = near_misses(parent, target)

        if near == [] do
          "Its parent #{parent} does exist. " <>
            "Next step: list it with dir_list to get the real name, then retry."
        else
          "Its parent #{parent} does exist and contains similarly-named entries: " <>
            "#{Enum.join(near, ", ")}. Next step: retry with one of those."
        end

      ancestor ->
        "The nearest existing ancestor is #{ancestor}. " <>
          "Next step: list it with dir_list to find the correct path, then retry."
    end
  end

  # Walk up until an existing directory is found. Bounded by the root.
  defp nearest_existing(path) do
    cond do
      File.exists?(path) -> path
      path in ["/", ".", ""] -> nil
      true -> nearest_existing(Path.dirname(path))
    end
  end

  defp near_misses(dir, target) do
    case File.ls(dir) do
      {:ok, entries} ->
        down = String.downcase(target)

        entries
        |> Enum.map(fn e -> {e, String.jaro_distance(down, String.downcase(e))} end)
        |> Enum.filter(fn {_e, score} -> score >= 0.75 end)
        |> Enum.sort_by(fn {_e, score} -> score end, :desc)
        |> Enum.take(5)
        |> Enum.map(fn {e, _} -> e end)

      _ ->
        []
    end
  end

  # ── Private: ripgrep path ─────────────────────────────────────────────

  defp try_ripgrep(pattern, path, opts) do
    max = opts[:max_results] || Constants.default_max_results()

    args = ["--no-heading", "--color", "never"]

    args =
      case opts[:output_mode] do
        "files_with_matches" -> args ++ ["-l"]
        "count" -> args ++ ["-c"]
        _ -> args ++ ["-n"]
      end

    args = args ++ ["-m", to_string(max)]
    args = if opts[:case_insensitive], do: args ++ ["-i"], else: args

    args =
      if opts[:context_lines], do: args ++ ["-C", to_string(opts[:context_lines])], else: args

    args = if opts[:glob], do: args ++ ["-g", opts[:glob]], else: args
    args = args ++ [pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, "No matches found."}
      {_, _} -> {:fallback, :rg_not_found}
    end
  rescue
    _ -> {:fallback, :rg_not_found}
  end

  # ── Private: Elixir fallback ──────────────────────────────────────────

  defp fallback_grep(pattern, path, opts) do
    regex_opts = if opts[:case_insensitive], do: "i", else: ""

    case Regex.compile(pattern, regex_opts) do
      {:error, _} ->
        {:error, "Invalid regex pattern: #{pattern}"}

      {:ok, r} ->
        files = collect_files(path, opts[:glob])
        max = opts[:max_results] || Constants.default_max_results()

        results =
          case opts[:output_mode] do
            "files_with_matches" ->
              Enum.filter(files, fn file ->
                case File.read(file) do
                  {:ok, content} -> Regex.match?(r, content)
                  _ -> false
                end
              end)

            "count" ->
              Enum.flat_map(files, fn file ->
                case File.read(file) do
                  {:ok, content} ->
                    count =
                      content |> String.split("\n") |> Enum.count(&Regex.match?(r, &1))

                    if count > 0, do: ["#{file}:#{count}"], else: []

                  _ ->
                    []
                end
              end)

            _ ->
              Enum.flat_map(files, fn file ->
                case File.read(file) do
                  {:ok, content} ->
                    content
                    |> String.split("\n")
                    |> Enum.with_index(1)
                    |> Enum.filter(fn {line, _} -> Regex.match?(r, line) end)
                    |> Enum.take(max)
                    |> Enum.map(fn {line, num} -> "#{file}:#{num}:#{line}" end)

                  _ ->
                    []
                end
              end)
          end

        case results do
          [] -> {:ok, "No matches found."}
          lines -> {:ok, lines |> Enum.join("\n") |> bound_output() |> with_spread_trailer()}
        end
    end
  end

  defp collect_files(path, glob) do
    if File.regular?(path) do
      [path]
    else
      file_pattern = glob || "**/*"

      Path.wildcard(Path.join(path, file_pattern))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(fn p ->
        Enum.any?(Constants.sensitive_paths(), &String.contains?(p, &1))
      end)
      |> Enum.take(Constants.max_fallback_files())
    end
  end

  @max_output_bytes Constants.max_output_bytes()

  @non_utf8_note "[note: some matched lines are not valid UTF-8 — the file is stored in a " <>
                   "non-UTF-8 encoding (latin-1/cp1252 or similar). Undecodable bytes are shown " <>
                   "as �; line numbers, columns and every other byte are unchanged. To see " <>
                   "the real characters, convert first: `shell_execute` with " <>
                   "`iconv -f <encoding> -t UTF-8 <path>`.]"

  # Bound the result AND guarantee it is valid UTF-8. Both halves are load-bearing:
  #
  #   * ripgrep prints matched lines as RAW BYTES. A latin-1 source file is
  #     text to `rg` — it is NOT skipped the way a binary file is — so one
  #     match is enough to hand OSA a binary `Jason.encode_to_iodata!/1`
  #     refuses. Measured: that raise is rescued into
  #     `{:error, "Provider error: invalid byte 0xDA"}`, the turn ends, and the
  #     session produces a 0-byte patch. `Utils.WireEncoding` now catches this
  #     at the provider boundary too, but the model still deserves to be told
  #     WHY the text looks odd rather than being handed silent mojibake.
  #
  #   * `String.slice/3` counts GRAPHEMES, not bytes, so the old cap was only
  #     accidentally correct on ASCII: against CJK it let through ~3x the byte
  #     budget, and against an invalid binary its behaviour is undefined.
  #     `Utils.Text.utf8_head/2` is byte-bounded and cuts on a codepoint
  #     boundary.
  defp bound_output(output) do
    note = if String.valid?(output), do: "", else: "\n\n" <> @non_utf8_note

    bounded =
      if byte_size(output) > @max_output_bytes do
        OptimalSystemAgent.Utils.Text.utf8_head(output, @max_output_bytes) <> "\n...[truncated]"
      else
        OptimalSystemAgent.Utils.Text.scrub_utf8(output)
      end

    bounded <> note
  end

  # A grep that lands in several files is the one moment the caller provably
  # holds a list of independent next reads. Ending the result with that count,
  # and with what to do about it, puts the batching signal in the last thing the
  # model saw rather than in a system prompt thousands of tokens behind it —
  # which is where the measurement says the guidance stops being obeyed:
  # read-only turns batch at 39% on turn 0 and 6% by turn 12, so a static
  # instruction is not what is carrying the behaviour late in a session.
  #
  # Only emitted when the matches actually span two or more files, so it never
  # advises a batch that does not exist.
  defp with_spread_trailer(output) do
    case distinct_match_files(output) do
      n when n > 1 ->
        output <>
          "\n\n(Matches span #{n} files. Reading them is independent work — " <>
          "issue those file_read calls together in one turn, not one per turn.)"

      _ ->
        output
    end
  end

  # Every emitted mode prefixes the path: `path:line:text` for the default and
  # `path:count` for counts, `path` alone for files_with_matches. Splitting on
  # the first `:` therefore names the file in all three, and context lines
  # (`path-line-text`) collapse onto the same key.
  defp distinct_match_files(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "--" or String.starts_with?(&1, "...[truncated]")))
    |> Enum.map(fn line ->
      line |> String.split(~r/[:\-]/, parts: 2) |> List.first()
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> length()
  end

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn p -> String.contains?(expanded_path, p) end)
  end

  defp allowed?(expanded_path) do
    check =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    Enum.any?(allowed_paths(), fn a -> String.starts_with?(check, a) end)
  end

  # Shared read allowlist — configured roots PLUS the session workspace. A
  # private copy here was blind to the session's `working_dir`.
  defp allowed_paths, do: OptimalSystemAgent.Agent.Safety.PathPolicy.read_roots()
end
