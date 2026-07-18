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
  @check_tools ~w(shell_execute file_read file_grep file_glob dir_list
                  code_symbols semantic_search codebase_explore repl
                  read_file grep_search list_dir)

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

  # --- Classification ---

  defp classify(tool) do
    name = to_string(tool)

    cond do
      name in @write_edit_tools -> :write
      write_like?(name) -> :write
      name in @check_tools -> :check
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

  @build_test_patterns [
    ~r/\bmix\s+(compile|test|format|dialyzer|credo)\b/,
    ~r/\b(npm|pnpm|yarn|bun)\s+(run\s+)?(test|build|lint|typecheck|tsc)\b/,
    ~r/\bgo\s+(build|test|vet)\b/,
    ~r/\bcargo\s+(build|test|check|clippy)\b/,
    ~r/\b(pytest|py\.test|unittest|tox)\b/,
    ~r/\b(make|cmake|gradle|mvn)\b/,
    ~r/\btsc\b/,
    ~r/\b(eslint|prettier|ruff|flake8|mypy|black)\b/
  ]

  defp build_or_test_command?(args) do
    case extract_command(args) do
      cmd when is_binary(cmd) -> Enum.any?(@build_test_patterns, &Regex.match?(&1, cmd))
      _ -> false
    end
  end

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
