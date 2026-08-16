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

  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Backend
  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @ignored_matches_note "\n\n(These matches are in files excluded by a .gitignore/.ignore rule " <>
                          "or hidden by a leading dot, so the default search skipped them. They " <>
                          "are shown because the default search found nothing — the paths are real.)"

  @no_matches_anywhere "No matches found. This search DID widen to the files an ordinary " <>
                         "search skips — .gitignore'd, hidden, and dependency/build directories " <>
                         "— so the pattern is genuinely absent from that path. Re-running it " <>
                         "through the shell will not give a different answer. If you expected a " <>
                         "hit, the pattern is wrong (regex metacharacters need escaping) or the " <>
                         "path is."

  @pruned_matches_note "\n\n(These matches are in dependency or build directories " <>
                         "(node_modules, .git, _build, deps, target, __pycache__, .venv), which " <>
                         "the ordinary search skips. They are shown because the ordinary search " <>
                         "found nothing — the paths are real.)"

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
  def execute(%{"pattern" => pattern} = params, ctx) do
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
      do_search(pattern, path, params, ctx)
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

  defp do_search(pattern, path, params, ctx) do
    rg_opts = %{
      glob: params["glob"],
      case_insensitive: params["case_insensitive"] == true,
      context_lines: params["context_lines"],
      output_mode: params["output_mode"],
      max_results: params["max_results"]
    }

    case try_ripgrep(pattern, path, rg_opts) do
      {:ok, output} ->
        {:ok, output |> bound_output() |> with_spread_trailer()}

      :empty ->
        empty_result(pattern, path, rg_opts, :ripgrep)

      # The substitution is no longer silent. `reason` distinguishes "ripgrep is
      # not installed on this node" — an environment problem an operator can
      # fix, and the one that served all 862 calls in the corpus — from "ripgrep
      # ran and exited badly", which is a different fault with a different fix.
      # The old code returned `{:fallback, :rg_not_found}` for both and logged
      # neither.
      {:fallback, reason} ->
        if reason == :missing, do: Backend.warn_missing_once(ctx)
        fallback_grep(pattern, path, rg_opts, {:fallback, reason})

      # Reported, attributable, and NOT a discarded turn: the model gets a named
      # failure for this one tool call and can narrow the path or the glob. The
      # alternative — falling through to `fallback_grep` — would answer a search
      # that hung with a result that looks like it ran, which is the same class
      # of silent wrong answer as the missing-path case above.
      {:timeout, ms} ->
        {:error,
         "file_grep: ripgrep did not finish within #{div(ms, 1000)}s and was stopped. " <>
           "The search was NOT completed, so this is not evidence that #{inspect(pattern)} " <>
           "is absent. A path that reaches a FIFO, a stalled network mount, or /proc will " <>
           "hang the search — narrow `path` (currently #{inspect(path)}) or set a `glob`, " <>
           "then try again."}
    end
  end

  # ── "No matches found." was a wrong answer 285 times in the corpus ────
  #
  # ripgrep does not search every file under the path it is given. By default it
  # obeys `.gitignore`, `.ignore` and `.rgignore` at every level, and skips
  # dotfiles. Nothing in the result said so, so a search that was never
  # performed came back indistinguishable from a search that found nothing —
  # the same silent-wrong-answer class as the missing-path case above, and the
  # more expensive one, because a missing path at least looks like an error.
  #
  # Measured across 118 SWE-bench/-Pro transcripts (862 `file_grep` calls):
  # 285 returned "No matches found." and 42 returned a missing-path error. Of
  # those, 58 were followed within six calls by a `shell_execute` grep for the
  # same token that DID return matches — the model routing around its own tool
  # and paying full shell price for it. 16 assistant turns say so outright:
  # *"the grep tool seems to have a systemic issue with this repo"*, *"the grep
  # for `parent_link` returned nothing — that's odd"*, *"the grep tool seems
  # unreliable here"*. Reproduced exactly in this repository: `bench/*/runs/` is
  # gitignored, so every benchmark workspace under it is invisible to
  # `file_grep` and fully visible to `grep -r`.
  #
  # So on an empty result — and ONLY on an empty result, which is where a second
  # exec is affordable and where a false negative is the whole cost — re-run
  # with the ignore rules and the dotfile skip lifted. If that finds something,
  # the matches were real and they are returned, with one sentence saying why
  # they needed asking for twice. If it finds nothing, the answer was honest and
  # says so in terms the model can act on.
  defp empty_result(pattern, path, opts, backend) do
    if Ablation.on?(:grep_coverage) do
      do_empty_result(pattern, path, opts, backend)
    else
      {:ok, "No matches found."}
    end
  end

  defp do_empty_result(pattern, path, opts, backend) do
    case try_ripgrep(pattern, path, opts, unrestricted: true) do
      {:ok, output} ->
        {:ok,
         (output <> @ignored_matches_note)
         |> bound_output()
         |> with_spread_trailer()}

      _ ->
        # "Nothing found" is the one answer a degraded backend gets wrong, so it
        # is the one answer that names the engine that produced it.
        {:ok, @no_matches_anywhere <> Backend.empty_result_note(backend)}
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

  defp try_ripgrep(pattern, path, opts, mode \\ []) do
    max = opts[:max_results] || Constants.default_max_results()

    args = ["--no-heading", "--color", "never"]

    # `--no-ignore` lifts .gitignore/.ignore/.rgignore; `--hidden` lifts the
    # dotfile skip. `.git/` stays excluded — pack files and loose objects are
    # binary noise that would drown the answer this pass exists to recover.
    args =
      if mode[:unrestricted],
        do: args ++ ["--no-ignore", "--hidden", "--glob", "!.git/"],
        else: args

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

    # Establish "is ripgrep installed" BEFORE spawning, rather than inferring it
    # from a rescued `:enoent`. The old code could not tell the two apart, which
    # is precisely why a node with no ripgrep at all looked identical to a node
    # where one search happened to fail — for 862 consecutive calls.
    case Backend.executable() do
      nil ->
        {:fallback, :missing}

      exe ->
        # `System.cmd/3` has no timeout, and this one had no wrapper either, so a
        # ripgrep that never returns never returned. That is not theoretical:
        # `rg` blocks indefinitely reading a FIFO, a dead NFS/SSHFS mount, or a
        # `/proc` pseudo-file that a broad `path` can walk into.
        #
        # Nothing above catches it. The tool Task has no deadline
        # (`:tool_timeout_ms` is `:infinity` by design — see `LongRunningToolTest`)
        # and the loop runs the turn on its own stack, so one wedged `rg` takes
        # the whole session with it until the 24h `GenServer.call` backstop.
        # Every other tool that shells out already bounds itself
        # (`shell_execute` 120s, `web_fetch` 30s, `github` 30s); this one and
        # `diff` were the exceptions, which makes them oversights against the
        # design rather than instances of it.
        #
        # The bound is on ONE subprocess, not on the turn, and it is deliberately
        # far above any real search (a cold `rg` over a large monorepo is single-
        # digit seconds). On expiry the tool reports what happened and the turn
        # continues with that answer — no turn is discarded and nothing is
        # silently downgraded.
        bounded_ripgrep(exe, args)
    end
  rescue
    # Backstop for what the lookup cannot see: the binary removed between
    # `find_executable/1` and the spawn, an exec-permission error, a bad
    # interpreter. Rare, and no longer how "not installed" is detected.
    _ -> {:fallback, :failed}
  end

  # Run ripgrep under a deadline, killing the OS process if it blows through it.
  #
  # `Task.shutdown(:brutal_kill)` tears down the Port, and closing a Port kills
  # the OS process it owns — so a wedged `rg` does not survive as an orphan
  # holding the mount that wedged it.
  defp bounded_ripgrep(exe, args) do
    task =
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
        System.cmd(exe, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, Constants.ripgrep_timeout_ms()) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      # ripgrep exits 1 for "no match". That is a real, trustworthy answer
      # from a real engine — not a fallback trigger.
      {:ok, {_output, 1}} ->
        :empty

      # 2+ means ripgrep ran and failed. A different fault from absence.
      {:ok, {_, _}} ->
        {:fallback, :failed}

      # The deadline fired, or the task died. `nil` from `Task.shutdown/2` is
      # the timeout case and is reported as itself — NOT folded into
      # `{:fallback, :failed}`, which would send the search quietly down the
      # pure-Elixir path and hand back a plausible-looking result for a search
      # that hung. Silent recovery is how a wedge stays invisible.
      nil ->
        {:timeout, Constants.ripgrep_timeout_ms()}

      {:exit, _reason} ->
        {:fallback, :failed}
    end
  end

  # ── Private: Elixir fallback ──────────────────────────────────────────
  #
  # This is not a rare path. `System.cmd("rg", …)` raises `:enoent` whenever the
  # ripgrep binary is not on the BEAM's PATH, and the rescue below turns that
  # into a fallback — silently. Measured on the 118-session corpus: of the 50
  # `file_grep` calls that asked for `context_lines` and got matches back, ZERO
  # results contain a single context line. The fallback ignored the parameter,
  # so every one of those 50 answers was served here. Not "sometimes" — the
  # ripgrep path never ran in any of the 118 sessions, and nothing said so.
  #
  # Three defects compounded on top of that, and together they are the
  # "systemic issue with this repo" the transcripts complain about:
  #
  #   1. **The file list was truncated to 500 after a full-tree walk.**
  #      `Path.wildcard("**/*") |> Enum.take(500)` keeps the first 500 paths in
  #      lexicographic order and discards the rest with no mention. Measured on
  #      the NodeBB workspace in `bench/`: 54,905 files, of which 500 were
  #      searched — **0.9%** — and the walk stopped inside `build/`, having
  #      never reached `src/` or `test/`. Every search of that repository
  #      answered "No matches found." from a 0.9% sample.
  #   2. **`glob` was not recursive.** `Path.join(path, "*.py")` matches the top
  #      level only, where `rg -g '*.py'` matches at any depth.
  #   3. **`context_lines` was dropped.**
  #
  # All three are fixed below, and the coverage cap now REPORTS itself. A search
  # that examined part of the tree and said nothing is the same failure as the
  # missing-path case at the top of this file: a confident wrong answer that
  # sends the agent down a false trail, and the one it is most expensive to
  # recover from because nothing looks broken.
  defp fallback_grep(pattern, path, opts, backend) do
    regex_opts = if opts[:case_insensitive], do: "i", else: ""

    case Regex.compile(pattern, regex_opts) do
      {:error, reason} ->
        {:error,
         "Invalid regex pattern: #{pattern} (#{inspect(reason)}). " <>
           "Escape regex metacharacters — `.` `*` `+` `?` `(` `)` `[` `]` `{` `}` `|` `^` `$` — " <>
           "if you meant them literally."}

      {:ok, r} ->
        {files, cut?} = collect_files(path, opts[:glob])

        if Ablation.on?(:grep_coverage) do
          covered_scan(files, r, opts, path, cut?, backend)
        else
          case scan(files, r, opts) do
            [] -> {:ok, "No matches found."}
            lines -> {:ok, emit(lines)}
          end
        end
    end
  end

  defp covered_scan(files, r, opts, path, cut?, backend) do
    case scan(files, r, opts) do
      [] ->
        # Nothing in the ordinary tree. Widen to the directories the walk
        # prunes, exactly as the ripgrep path widens to ignored and hidden
        # files, so the two backends answer the same question.
        {pruned, pruned_cut?} = collect_files(path, opts[:glob], pruned_only: true)

        case scan(pruned, r, opts) do
          [] ->
            {:ok,
             @no_matches_anywhere <>
               coverage_note(cut? or pruned_cut?) <> Backend.empty_result_note(backend)}

          lines ->
            {:ok, emit(lines) <> @pruned_matches_note}
        end

      lines ->
        {:ok, emit(lines) <> coverage_note(cut?)}
    end
  end

  defp emit(lines), do: lines |> Enum.join("\n") |> bound_output() |> with_spread_trailer()

  defp coverage_note(false), do: ""

  defp coverage_note(true) do
    "\n\n(Coverage limit: this search examined the first " <>
      "#{Constants.max_fallback_files()} files under that path and there are more. " <>
      "The result is therefore a lower bound, NOT proof of absence. Narrow it with a " <>
      "more specific `path` or a `glob` and search again.)"
  end

  defp scan(files, r, opts) do
    max = opts[:max_results] || Constants.default_max_results()

    case opts[:output_mode] do
      "files_with_matches" ->
        Enum.flat_map(files, fn file ->
          case File.read(file) do
            {:ok, content} -> if Regex.match?(r, content), do: [file], else: []
            _ -> []
          end
        end)

      "count" ->
        Enum.flat_map(files, fn file ->
          with {:ok, content} <- File.read(file),
               count when count > 0 <-
                 content |> String.split("\n") |> Enum.count(&Regex.match?(r, &1)) do
            ["#{file}:#{count}"]
          else
            _ -> []
          end
        end)

      _ ->
        Enum.flat_map(files, &scan_lines(&1, r, max, opts[:context_lines]))
    end
  end

  # `context_lines` is honoured here now, in ripgrep's own output shape: a
  # matched line is `path:line:text`, a context line is `path-line-text`, and
  # non-adjacent groups are separated by `--`. The separator characters are what
  # let a reader (and `distinct_match_files/1` below) tell the two apart.
  defp scan_lines(file, r, max, context) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        hits =
          lines
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(r, line) end)
          |> Enum.take(max)
          |> Enum.map(&elem(&1, 1))

        cond do
          hits == [] -> []
          context in [nil, 0] -> Enum.map(hits, &"#{file}:#{&1}:#{Enum.at(lines, &1 - 1)}")
          true -> with_context(file, lines, hits, context)
        end

      _ ->
        []
    end
  end

  defp with_context(file, lines, hits, context) do
    wanted = MapSet.new(hits)

    ranges =
      Enum.map(hits, fn n -> max(n - context, 1)..min(n + context, length(lines)) end)

    ranges
    |> Enum.flat_map(&Enum.to_list/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn n, acc ->
        case acc do
          [] -> {:cont, [n]}
          [prev | _] when n == prev + 1 -> {:cont, [n | acc]}
          _ -> {:cont, Enum.reverse(acc), [n]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.map(fn group ->
      Enum.map_join(group, "\n", fn n ->
        sep = if MapSet.member?(wanted, n), do: ":", else: "-"
        "#{file}#{sep}#{n}#{sep}#{Enum.at(lines, n - 1)}"
      end)
    end)
    |> Enum.intersperse("--")
  end

  # Walk the tree ourselves rather than through `Path.wildcard/2`, so the prune
  # list is applied to DIRECTORIES and a `node_modules` costing 50,000 files is
  # never enumerated at all. That is what makes the budget affordable enough to
  # raise: the cap now bounds source files, not dependency noise.
  #
  # Returns `{files, truncated?}` — the boolean is the whole point. A caller
  # that cannot tell a complete search from a partial one cannot tell "absent"
  # from "not looked at".
  @pruned_dirs ~w(.git node_modules _build deps target __pycache__ .venv venv
                  .tox .mypy_cache .pytest_cache .next .nuxt .gradle vendor)

  defp collect_files(path, glob, mode \\ []) do
    if File.regular?(path) do
      {[path], false}
    else
      cap = Constants.max_fallback_files()

      files =
        path
        |> walk(mode[:pruned_only] == true)
        |> Stream.reject(fn p ->
          Enum.any?(Constants.sensitive_paths(), &String.contains?(p, &1))
        end)
        |> Stream.filter(&glob_match?(&1, path, glob))
        # One more than the cap, so "exactly at the cap" is distinguishable
        # from "more than the cap" without walking the rest of the tree.
        |> Enum.take(cap + 1)

      {Enum.take(files, cap), length(files) > cap}
    end
  end

  defp walk(dir, pruned_only?) do
    Stream.resource(
      fn -> [dir] end,
      fn
        [] ->
          {:halt, []}

        [current | rest] ->
          case File.ls(current) do
            {:ok, entries} ->
              {dirs, files} =
                entries
                |> Enum.sort()
                |> Enum.map(&Path.join(current, &1))
                |> Enum.split_with(&File.dir?/1)

              keep =
                Enum.filter(dirs, fn d ->
                  pruned? = Path.basename(d) in @pruned_dirs
                  if pruned_only?, do: true, else: not pruned?
                end)

              {Enum.filter(files, &File.regular?/1), keep ++ rest}

            _ ->
              {[], rest}
          end
      end,
      fn _ -> :ok end
    )
  end

  # `rg -g` semantics: a glob with no `/` matches the BASENAME at any depth; a
  # glob with a `/` is matched against the path relative to the search root.
  defp glob_match?(_file, _root, nil), do: true

  defp glob_match?(file, root, glob) do
    if String.contains?(glob, "/") do
      rel = Path.relative_to(file, root)

      Regex.match?(glob_regex(glob), rel) or
        Regex.match?(glob_regex(String.replace_prefix(glob, "**/", "")), rel)
    else
      Regex.match?(glob_regex(glob), Path.basename(file))
    end
  end

  # A glob compiled once per distinct pattern and cached in the process
  # dictionary — `glob_match?/3` runs once per file, and recompiling the same
  # regex tens of thousands of times per search is the difference between this
  # walk being affordable and not.
  defp glob_regex(glob) do
    key = {:osa_file_grep_glob, glob}

    case Process.get(key) do
      nil ->
        r = compile_glob(glob)
        Process.put(key, r)
        r

      r ->
        r
    end
  end

  # `**` crosses directory separators, `*` does not, `?` is one non-separator
  # character. Everything else is literal.
  defp compile_glob(glob) do
    # Private-use codepoints as placeholders: `Regex.escape/1` leaves them
    # alone, and no real path contains them.
    body =
      glob
      |> String.replace("**/", "")
      |> String.replace("**", "")
      |> String.replace("*", "")
      |> String.replace("?", "")
      |> Regex.escape()
      |> String.replace("", "(?:.*/)?")
      |> String.replace("", ".*")
      |> String.replace("", "[^/]*")
      |> String.replace("", "[^/]")

    Regex.compile!("^" <> body <> "$")
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
