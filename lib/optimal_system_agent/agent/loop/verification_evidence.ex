defmodule OptimalSystemAgent.Agent.Loop.VerificationEvidence do
  @moduledoc """
  Evidence ledger backing the grounded verification gate (P1-3).

  The old gate decided "verified" by whether a tool whose *name* contained
  `read`/`test`/`grep`/`shell`/`exec` appeared after a write. It never checked
  that the verification **passed** (exit 0) or that it **touched the changed
  files**, so it could be trivially spoofed by an unrelated `file_read` or by a
  `shell_execute` that exited non-zero.

  This ledger records each tool call as structured evidence:

      %{
        tool: "shell_execute",
        kind: :write | :check | :other,
        paths: [abs, ...],        # explicit file targets (file_* tools)
        command: "mix compile",   # raw command (shell tools)
        build_or_test: true,      # command looks like a project build/test
        success: true,            # tool exited 0 / did not error
        ts: monotonic_int
      }

  "Did a real check pass on the changed files" then becomes a factual query
  (`pending_files/1`, `verified?/1`) rather than a name heuristic.

  Storage is a session-scoped ETS table so it can be written from the tool
  executor (where tools actually run) and read from the gate without threading
  state through the loop.
  """

  @table :osa_verification_ledger

  # Cap ledger length per session to bound memory on very long runs.
  @max_entries 200

  # Recent window the gate reasons over (mirrors the sliding window the loop
  # keeps for DoomLoop). Older writes are considered settled.
  @window 40

  @write_edit_tools ~w(file_write file_edit multi_file_edit notebook_edit
                       write_file edit_file apply_patch str_replace
                       str_replace_editor create_file file_append multi_edit
                       file_create)

  # Tools that produce a grounded external signal about the workspace.
  # Tools that EXECUTE and can therefore FAIL. A grounded check is one the
  # workspace can refuse.
  @check_tools ~w(shell_execute repl code_sandbox)

  # Tools that only LOOK. These used to be `@check_tools`, so re-reading a file
  # counted as having verified the edit to it — and the gate's own directive
  # advertises re-reading as a way to satisfy it, while `file_edit`'s prompt
  # simultaneously tells the model "do NOT re-read the file to verify an edit
  # that succeeded". The gate taught the model how to discharge a pending write
  # without running anything. A read reports what a file SAYS, not whether it
  # WORKS.
  @read_tools ~w(file_read file_grep file_glob dir_list code_symbols
                 semantic_search codebase_explore read_file grep_search
                 list_dir)

  @doc "Record a tool call as evidence. `success` is the exit-0 / no-error signal."
  @spec record(term(), map()) :: :ok
  def record(session_id, %{tool: tool} = call) when not is_nil(session_id) do
    ensure_table()

    entry = %{
      tool: to_string(tool),
      kind: classify(tool),
      paths: extract_paths(Map.get(call, :args) || %{}),
      command: extract_command(Map.get(call, :args) || %{}),
      build_or_test: build_or_test_command?(Map.get(call, :args) || %{}),
      # Recorded separately so a gate can require a TEST — which asserts
      # behaviour — rather than accepting a build, which only asserts it
      # compiles. They were one predicate, so `go build` passing covered a red
      # test.
      test_command: test_command?(Map.get(call, :args) || %{}),
      # Paths this call CREATED OR OVERWROTE. For a write tool that is its
      # `path` argument; for a shell command it is every redirection / `tee`
      # target. Without the shell half the ledger is blind to the single most
      # common way a model writes a file — `cat > f << 'EOF'` — which is
      # exactly how the `cancel-async-tasks` run produced its deliverable, so
      # the gate saw a session with NO writes at all and never fired.
      written_paths: written_paths(Map.get(call, :args) || %{}, tool),
      # Paths this call RAN or READ (path-like tokens in the command that are
      # not redirection targets). A test invocation names its test file here;
      # an inline `python3 - << PY` heredoc names nothing, which is the whole
      # point — see `discriminating_evidence/1`.
      ran_paths: ran_paths(Map.get(call, :args) || %{}),
      success: Map.get(call, :success, false) == true,
      ts: System.monotonic_time()
    }

    list = get(session_id)
    updated = Enum.take(list ++ [entry], -@max_entries)
    :ets.insert(@table, {session_id, updated})
    :ok
  rescue
    _ -> :ok
  end

  def record(_session_id, _call), do: :ok

  @doc "All evidence entries for a session (oldest first)."
  @spec entries(term()) :: [map()]
  def entries(session_id), do: get(session_id)

  @doc "Drop a session's ledger (test isolation / session end)."
  @spec reset(term()) :: :ok
  def reset(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Files that were successfully written but have **no** grounded, passing check
  covering them *since their last write*. Empty list => nothing pending.
  """
  @spec pending_files(term()) :: [String.t()]
  def pending_files(session_id) do
    window = session_id |> get() |> Enum.take(-@window)
    indexed = Enum.with_index(window)

    # Last successful write index per changed file.
    last_writes =
      for {%{kind: :write, success: true, paths: paths}, idx} <- indexed,
          path <- paths,
          into: %{} do
        {path, idx}
      end

    for {path, widx} <- last_writes,
        not covered_after?(indexed, path, widx),
        do: path
  end

  @doc "True when no changed file is awaiting a grounded passing check."
  @spec verified?(term()) :: boolean()
  def verified?(session_id), do: pending_files(session_id) == []

  @doc "The most recent successful write tool name, for directive messaging."
  @spec last_write_tool(term()) :: String.t() | nil
  def last_write_tool(session_id) do
    session_id
    |> get()
    |> Enum.reverse()
    |> Enum.find(fn e -> e.kind == :write and e.success end)
    |> case do
      nil -> nil
      e -> e.tool
    end
  end

  # --- Coverage ---

  # A file X is covered when, at some index AFTER its last write, there is a
  # successful check that (a) is a project-wide build/test, (b) names X in its
  # paths, or (c) references X's basename in its command string.
  defp covered_after?(indexed, path, widx) do
    base = Path.basename(path)

    Enum.any?(indexed, fn {entry, idx} ->
      idx > widx and entry.kind == :check and entry.success and
        (entry.build_or_test or
           path in entry.paths or
           basename_referenced?(entry, path, base))
    end)
  end

  defp basename_referenced?(%{command: cmd}, _path, base)
       when is_binary(cmd) and byte_size(base) > 0,
       do: String.contains?(cmd, base)

  defp basename_referenced?(_entry, _path, _base), do: false

  @doc """
  The most recent check that RAN and FAILED since the last source write, if any.

  Two independent studies of our own transcripts converged here. Every harness
  examined — ours included — gates on the ABSENCE of verification and none on
  the PRESENCE of a failure: `tool_executor` records `success: false` for a
  failing test and the loop then discards it. Meanwhile, in 12 of 15 failed
  benchmark instances no check ran after the final source edit at all, and
  every check that DID run after one passed. Nobody ends on a red test; they
  end on an untested edit.

  So the two signals are different and both are needed. `pending_files/1`
  answers "was this edit ever checked". This answers "was it checked and did
  the check fail", which is the signal that was being thrown away.
  """
  @spec failing_check_since_write(String.t()) :: map() | nil
  def failing_check_since_write(session_id) do
    indexed = session_id |> get() |> Enum.take(-@window) |> Enum.with_index()

    last_write_idx =
      indexed
      |> Enum.filter(fn {e, _} -> e.kind == :write end)
      |> List.last()
      |> case do
        {_e, idx} -> idx
        nil -> nil
      end

    case last_write_idx do
      nil ->
        nil

      widx ->
        after_write = Enum.filter(indexed, fn {_e, idx} -> idx > widx end)

        after_write
        |> Enum.filter(fn {e, _} -> e.kind == :check and not e.success end)
        |> List.last()
        |> case do
          {entry, idx} -> unless resolved?(entry, idx, after_write), do: entry
          nil -> nil
        end
    end
  rescue
    _ -> nil
  end

  # A red result stops being a reason to keep working once it has been
  # SUPERSEDED. Without this the flag is sticky until the next write, which is
  # a measured waste: in a live session an ad-hoc probe failed once, the two
  # commands after it passed, and the gate still spent its whole re-prompt
  # budget demanding a fix for something already fixed.
  #
  # Two ways to supersede, and the asymmetry is the point:
  #
  #   * the SAME check ran again and passed (same test file / same suite) — the
  #     only thing that clears a red BUILD OR TEST, which is the case the
  #     "nobody ends on a red test" finding was actually about; or
  #   * the red thing was an ad-hoc probe (not a build, not a test) and
  #     something later ran green. A throwaway probe erroring is weak evidence
  #     and must not hold the turn hostage — and it no longer needs to, because
  #     a probe-only session is now stopped by the adequacy requirement instead.
  defp resolved?(entry, idx, after_write) do
    later_success = for {e, i} <- after_write, i > idx, e.kind == :check, e.success, do: e

    cond do
      later_success == [] ->
        false

      not Map.get(entry, :build_or_test, false) ->
        true

      true ->
        ids = check_identity_keys(entry)

        ids != [] and
          Enum.any?(later_success, fn e ->
            not MapSet.disjoint?(MapSet.new(ids), MapSet.new(check_identity_keys(e)))
          end)
    end
  end

  # "Which recurring check is this" — the same notion `test_identities/2` uses,
  # minus the persistence requirement, because comparing a red run to a green
  # run of the same command does not depend on the file still being on disk.
  defp check_identity_keys(entry) do
    ran = Map.get(entry, :ran_paths, [])
    wrote = Map.get(entry, :written_paths, [])
    files = ran |> Enum.reject(&(&1 in wrote)) |> Enum.filter(&test_artifact_path?/1)

    suite =
      case suite_key(Map.get(entry, :command)) do
        nil -> []
        key -> [key]
      end

    files ++ suite
  end

  @doc """
  Whether a TEST (not merely a build) has passed since the last source write.

  `pending_files/1` accepts any successful build-or-test, so `go build`
  succeeding discharged an edit whose test was red. This is the stricter claim
  a completion gate should want.
  """
  @spec tested_since_write?(String.t()) :: boolean()
  def tested_since_write?(session_id) do
    indexed = session_id |> get() |> Enum.take(-@window) |> Enum.with_index()

    last_write_idx =
      indexed
      |> Enum.filter(fn {e, _} -> e.kind == :write end)
      |> List.last()
      |> case do
        {_e, idx} -> idx
        nil -> nil
      end

    case last_write_idx do
      # No write at all: nothing to test, so nothing is outstanding.
      nil ->
        true

      widx ->
        Enum.any?(indexed, fn {e, idx} ->
          idx > widx and e.kind == :check and e.success and Map.get(e, :test_command, false)
        end)
    end
  rescue
    _ -> true
  end

  # --- Classification ---

  defp classify(tool) do
    name = to_string(tool)

    cond do
      name in @write_edit_tools -> :write
      write_like?(name) -> :write
      name in @check_tools -> :check
      # A read is NOT a check. It reports what a file says, not whether the
      # change works — and the gate's own directive advertises re-reading as a
      # way to satisfy it, so classifying reads as checks taught the model how
      # to discharge a pending write without running anything.
      name in @read_tools -> :read
      check_like?(name) -> :check
      true -> :other
    end
  end

  defp write_like?(name) do
    down = String.downcase(name)

    String.contains?(down, "write") or String.contains?(down, "edit") or
      String.contains?(down, "patch")
  end

  defp check_like?(name) do
    down = String.downcase(name)

    String.contains?(down, "read") or String.contains?(down, "shell") or
      String.contains?(down, "exec") or String.contains?(down, "grep") or
      String.contains?(down, "test")
  end

  # --- Argument extraction ---

  defp extract_paths(args) when is_map(args) do
    single = List.wrap(Map.get(args, "path"))

    multi =
      case Map.get(args, "files") do
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{"path" => p} -> [p]
            p when is_binary(p) -> [p]
            _ -> []
          end)

        _ ->
          []
      end

    (single ++ multi)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.uniq()
  end

  defp extract_paths(_), do: []

  defp normalize_path(p) do
    Path.expand(p)
  rescue
    _ -> p
  end

  defp extract_command(args) when is_map(args) do
    case Map.get(args, "command") || Map.get(args, "code") do
      c when is_binary(c) -> c
      _ -> nil
    end
  end

  defp extract_command(_), do: nil

  # A TEST asserts behaviour. A build only asserts it compiles.
  #
  # These were one list, so `go build` succeeding discharged an edit whose test
  # was red. They are separated because they are different claims, and only the
  # first is what a completion gate should require.
  #
  # `run_tests.sh` matters specifically: a benchmark harness — and plenty of
  # real repos — put the canonical test command in a script, and the old
  # patterns matched none of them, so the single most authoritative check
  # available registered as nothing at all.
  @test_patterns [
    ~r/\bmix\s+test\b/,
    ~r/\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b/,
    ~r/\bgo\s+test\b/,
    ~r/\bcargo\s+(test|nextest)\b/,
    ~r/\b(pytest|py\.test|unittest|tox|nose2)\b/,
    ~r/\bpython[0-9.]*\s+-m\s+(pytest|unittest)\b/,
    ~r/\b(rspec|jest|vitest|mocha|phpunit|ctest)\b/,
    ~r/\bruntests\.py\b/,
    ~r/(^|[\s;&|])\.?\/?run_tests\.sh\b/,
    ~r/(^|[\s;&|])(bash|sh)\s+\S*run_tests\.sh\b/,
    ~r/\bmake\s+(test|check)\b/
  ]

  @build_patterns [
    ~r/\bmix\s+(compile|format|dialyzer|credo)\b/,
    ~r/\b(npm|pnpm|yarn|bun)\s+(run\s+)?(build|lint|typecheck|tsc)\b/,
    ~r/\bgo\s+(build|vet)\b/,
    ~r/\bcargo\s+(build|check|clippy)\b/,
    ~r/\b(make|cmake|gradle|mvn)\b/,
    ~r/\btsc\b/,
    ~r/\b(eslint|prettier|ruff|flake8|mypy|black)\b/
  ]

  @build_test_patterns @test_patterns ++ @build_patterns

  defp build_or_test_command?(args) do
    case extract_command(args) do
      cmd when is_binary(cmd) -> Enum.any?(@build_test_patterns, &Regex.match?(&1, cmd))
      _ -> false
    end
  end

  @doc "True when the command runs TESTS, as opposed to merely building."
  @spec test_command?(map()) :: boolean()
  def test_command?(args) do
    case extract_command(args) do
      cmd when is_binary(cmd) -> Enum.any?(@test_patterns, &Regex.match?(&1, cmd))
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Adequacy: a PERSISTED, RE-RUNNABLE test that FAILED AT LEAST ONCE
  # ---------------------------------------------------------------------------
  #
  # `pending_files/1` is a LIVENESS check: "something exited 0 and touched the
  # changed file". It is satisfiable by a probe the model writes in order to
  # satisfy it, and on `cancel-async-tasks` that is exactly what happened —
  # five throwaway `python3 - << 'PYEOF'` heredocs, zero persisted test files,
  # a "**Verified:** concurrency cap respected" claim, and a wrong answer in 13
  # turns. The harness that solved the same task took 56 turns, wrote four
  # named test files, and iterated write -> test -> fix four times.
  #
  # This section asks the ADEQUACY question instead, in three parts, each of
  # which closes a specific cheap path:
  #
  #   * **Persisted** — the evidence must be a named file on disk (or a project
  #     test-suite invocation). An inline heredoc vanishes; it cannot be
  #     re-run, reviewed, or shipped. It is also the single cheapest thing a
  #     model can emit, which is why it was the observed behaviour.
  #
  #   * **Re-runnable** — the check must invoke that file by path, so invoking
  #     it again is possible and exercises the change.
  #
  #   * **Failed at least once, with a source fix in between** — a test that
  #     has only ever passed may be testing nothing. A test that failed, then a
  #     SOURCE file changed, then it passed, demonstrably discriminates. The
  #     "source fix in between" clause is what stops the obvious counter-play
  #     of writing `assert False`, watching it fail, and editing the assertion.

  # File extensions that make a change "code", i.e. something a test could
  # exercise. A docs- or config-only change has no runnable test and must not
  # be blocked — that is the automatic half of the escape hatch.
  @code_extensions ~w(.py .ex .exs .go .rs .ts .tsx .js .jsx .mjs .cjs .rb
                      .java .kt .scala .c .h .cpp .cc .hpp .cs .php .swift
                      .lua .pl .pm .m .mm .erl .hrl .clj .sh .bash .zsh .sql)

  @doc """
  True when `path` names something a test could exercise. Docs, config and
  data files answer `false`, which is what lets a documentation-only task
  finish without a test.
  """
  @spec code_file?(String.t()) :: boolean()
  def code_file?(path) when is_binary(path) do
    String.downcase(Path.extname(path)) in @code_extensions
  end

  def code_file?(_), do: false

  @test_basename_patterns [
    ~r/^test_.+\.(py|rb|js|ts|tsx|jsx|mjs|sh|bash|lua|pl)$/i,
    ~r/_test\.(py|go|exs|ex|rb|ts|js|rs|java|kt|c|cc|cpp)$/i,
    ~r/\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs)$/i,
    ~r/_spec\.(rb|ex|exs|js|ts)$/i,
    ~r/^(run_tests|runtests|run_test)\.(sh|bash|py)$/i,
    ~r/^tests?\.(py|sh|bash|js|ts|exs|rb)$/i
  ]

  @test_dir_segments ~w(test tests spec specs __tests__ testing)

  @doc """
  True when `path` is a test artefact by convention — `test_*.py`, `*_test.go`,
  `*.spec.ts`, `run_tests.sh`, anything under a `test/`, `tests/`, `spec/` or
  `__tests__/` directory.

  Convention, not content analysis, on purpose: the gate's directive tells the
  model exactly this rule, so satisfying it honestly is cheap and unambiguous.
  Naming a file `test_x.py` is not the part we are trying to make expensive —
  making it *discriminate* is.
  """
  @spec test_artifact_path?(String.t()) :: boolean()
  def test_artifact_path?(path) when is_binary(path) do
    base = Path.basename(path)

    Enum.any?(@test_basename_patterns, &Regex.match?(&1, base)) or
      Enum.any?(Path.split(Path.dirname(path)), &(String.downcase(&1) in @test_dir_segments))
  end

  def test_artifact_path?(_), do: false

  @doc """
  True when the session has changed code but has produced **no** discriminating
  test evidence for it.

  This is the gate's adequacy trigger. It is deliberately silent when:

    * nothing was written, or
    * only non-code files were written (docs / config — nothing to test), or
    * discriminating evidence already exists.
  """
  @spec needs_discriminating_test?(term()) :: boolean()
  def needs_discriminating_test?(session_id) do
    entries = get(session_id)

    source_changed? =
      entries
      |> source_write_indices()
      |> Enum.any?()

    source_changed? and discriminating_evidence(entries) == nil
  rescue
    _ -> false
  end

  @doc """
  The discriminating test evidence for this session, or `nil`.

  Returns `%{artifact: id, failed_at: i, fixed_at: j, passed_at: k}` where `id`
  is `{:file, path}` for a named test file or `{:suite, key}` for a project
  test-runner invocation, and `i < j < k` are ledger indices satisfying:

      the test RAN and FAILED   ->   a SOURCE file was written   ->   the same
      test RAN and PASSED

  That triple is the write -> test -> fix loop, stated as a property of the
  transcript. Nothing weaker is accepted.
  """
  @spec discriminating_evidence(term() | [map()]) :: map() | nil
  def discriminating_evidence(session_id) when not is_list(session_id) do
    discriminating_evidence(get(session_id))
  end

  def discriminating_evidence(entries) when is_list(entries) do
    indexed = Enum.with_index(entries)
    written = written_path_set(entries)
    fixes = source_write_indices(entries)

    if fixes == [] do
      nil
    else
      indexed
      |> Enum.flat_map(fn {entry, idx} ->
        for id <- test_identities(entry, written), do: {id, idx, entry.success}
      end)
      |> Enum.group_by(fn {id, _, _} -> id end)
      |> Enum.find_value(fn {id, runs} ->
        fails = for {_, idx, false} <- runs, do: idx
        passes = for {_, idx, true} <- runs, do: idx

        with i when is_integer(i) <- Enum.min(fails, fn -> nil end),
             j when is_integer(j) <- Enum.find(fixes, &(&1 > i)),
             k when is_integer(k) <- Enum.find(passes, &(&1 > j)) do
          %{artifact: id, failed_at: i, fixed_at: j, passed_at: k}
        else
          _ -> nil
        end
      end)
    end
  rescue
    _ -> nil
  end

  @doc """
  Test artefacts the session has produced or run, for directive messaging.
  """
  @spec known_test_artifacts(term()) :: [String.t()]
  def known_test_artifacts(session_id) do
    entries = get(session_id)
    written = written_path_set(entries)

    entries
    |> Enum.flat_map(fn e ->
      for {:file, p} <- test_identities(e, written), do: p
    end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc "Code files the session successfully wrote (the change under test)."
  @spec changed_source_files(term()) :: [String.t()]
  def changed_source_files(session_id) do
    session_id
    |> get()
    |> Enum.filter(&(&1.success and not test_entry?(&1)))
    |> Enum.flat_map(&Map.get(&1, :written_paths, []))
    |> Enum.filter(&code_file?/1)
    |> Enum.reject(&test_artifact_path?/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  # Indices of successful writes to a NON-test code file. These are the "fix"
  # events: the thing that must happen between a red run and a green one for
  # the green to mean anything. A write to the test file itself is excluded,
  # which is what closes the `assert False` -> edit-the-assertion play.
  defp source_write_indices(entries) do
    entries
    |> Enum.with_index()
    |> Enum.filter(fn {e, _idx} ->
      e.success and
        Enum.any?(Map.get(e, :written_paths, []), fn p ->
          code_file?(p) and not test_artifact_path?(p)
        end)
    end)
    |> Enum.map(fn {_e, idx} -> idx end)
  end

  defp test_entry?(e), do: Enum.all?(Map.get(e, :written_paths, []), &test_artifact_path?/1)

  defp written_path_set(entries) do
    for e <- entries, p <- Map.get(e, :written_paths, []), into: MapSet.new(), do: p
  end

  # What re-runnable test this call invoked, if any.
  #
  # An entry yields an identity ONLY when it names a persisted test artefact it
  # did not itself write, or when it invokes a project test runner. Every
  # cheaper shape yields `[]`:
  #
  #   python3 - << 'PY' ...     -> no path token       -> []
  #   python3 -c "import run"   -> no path token       -> []
  #   cat > /tmp/test_x.py <<EOF -> path is a WRITE     -> []
  #   python3 /tmp/test_x.py    -> persisted + re-runnable -> [{:file, ...}]
  #   mix test / pytest         -> project suite       -> [{:suite, key}]
  defp test_identities(%{kind: :check} = entry, written) do
    ran = Map.get(entry, :ran_paths, [])
    wrote = Map.get(entry, :written_paths, [])

    files =
      ran
      |> Enum.reject(&(&1 in wrote))
      |> Enum.filter(&test_artifact_path?/1)
      |> Enum.filter(&persisted?(&1, written))
      |> Enum.map(&{:file, &1})

    suite =
      if files == [] and Map.get(entry, :test_command, false) do
        case suite_key(Map.get(entry, :command)) do
          nil -> []
          key -> [{:suite, key}]
        end
      else
        []
      end

    files ++ suite
  end

  defp test_identities(_entry, _written), do: []

  # "Persisted" means the file is on disk now, OR the ledger itself watched it
  # being written. The second clause matters because the shell the agent drives
  # is not always the filesystem this process can stat (benchmark containers,
  # remote sessions) — without it the gate would silently never pass there.
  defp persisted?(path, written) do
    MapSet.member?(written, path) or File.exists?(path)
  rescue
    _ -> MapSet.member?(written, path)
  end

  # Suite identity is the *runner*, not the exact command line, so
  # `mix test a_test.exs` and `mix test` are the same recurring check.
  defp suite_key(cmd) when is_binary(cmd) do
    @test_patterns
    |> Enum.find_index(&Regex.match?(&1, cmd))
    |> case do
      nil -> nil
      i -> "test_pattern_#{i}"
    end
  end

  defp suite_key(_), do: nil

  # --- Shell argument parsing ---

  # `> f`, `>> f`, `2> f`, `| tee f`, `| tee -a f`.
  @redirect_re ~r/(?:^|[\s;&|])(?:\d?>>?\s*|\|\s*tee\s+(?:-a\s+)?)(['"]?)([^\s'"<>|;&]+)\1/

  defp written_paths(args, tool) when is_map(args) do
    from_tool =
      if classify(tool) == :write do
        extract_paths(args)
      else
        []
      end

    from_shell =
      case extract_command(args) do
        cmd when is_binary(cmd) ->
          @redirect_re
          |> Regex.scan(cmd)
          |> Enum.map(fn m -> List.last(m) end)
          |> Enum.filter(&plausible_path?/1)
          |> Enum.map(&normalize_path/1)

        _ ->
          []
      end

    Enum.uniq(from_tool ++ from_shell)
  end

  defp written_paths(_, _), do: []

  # Path-like tokens in a command. Deliberately conservative: a token must look
  # like a filename (has an extension) or contain a `/`.
  @token_re ~r/[A-Za-z0-9_@%+=:,.\/~^-]+/

  defp ran_paths(args) when is_map(args) do
    case extract_command(args) do
      cmd when is_binary(cmd) ->
        @token_re
        |> Regex.scan(cmd)
        |> Enum.map(&hd/1)
        |> Enum.filter(&plausible_path?/1)
        |> Enum.map(&normalize_path/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp ran_paths(_), do: []

  defp plausible_path?(tok) when is_binary(tok) do
    byte_size(tok) > 1 and byte_size(tok) < 512 and
      not String.starts_with?(tok, "-") and
      (String.contains?(tok, "/") or Path.extname(tok) != "") and
      not String.ends_with?(tok, "/")
  end

  defp plausible_path?(_), do: false

  # --- ETS backing ---

  defp get(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, list}] when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
