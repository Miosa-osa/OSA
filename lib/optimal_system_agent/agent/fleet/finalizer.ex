defmodule OptimalSystemAgent.Agent.Fleet.Finalizer do
  @moduledoc """
  Fleet orchestration finalizer (FLEET_ORCHESTRATION O3).

  Turns a completed *isolated* `Fleet.fan_out` into a single merged, gated,
  committed result — the step that makes the disjoint-workstream flow
  self-verifying. After every fan-out node reports back, the finalizer:

    1. **Conflict-checks** — the orchestrator was supposed to partition the work
       into DISJOINT file-owned workstreams. If two nodes touched the SAME file,
       that is an overlap the finalizer must NOT clobber: the conflicted files
       are reported and skipped, never merged.
    2. **Merges disjoint diffs** — for each node that ran in its own worktree
       (`worktree_ref`), its non-conflicting `files_changed` are brought into the
       current branch via `git checkout <worktree_ref> -- <files>`.
    3. **Runs one authoritative gate** — a configured `gate_cmds` list (e.g.
       `["mix compile", "mix test <targets>"]`) is executed in order; the first
       non-zero exit stops the gate and marks it `:fail`. Node self-gates are
       advisory — this combined gate is the only source of "green".
    4. **Commits when green** — iff there were no conflicts AND the gate passed
       (or was skipped) AND a `:commit` message was supplied, the merged changes
       are committed **attribution-clean** using the caller's message verbatim.
       The finalizer NEVER appends a `Co-Authored-By` / AI footer, and NEVER
       pushes (the outward step stays operator-gated).

  ## Frozen input contract

  `node_results` is a list of maps produced by `Fleet.fan_out` (O2), each:

      %{
        node_id: binary,
        worktree_ref: binary | nil,
        files_changed: [binary],
        gate: :pass | :fail | :skipped,
        stubbed: [binary],
        summary: binary,
        error: term | nil
      }

  Nodes with a non-nil `:error` contributed no trustworthy diff and are excluded
  from the merge (their files are still counted for conflict detection).

  ## Injectable IO seams (fully unit-testable)

  All shell/git IO is behind two function seams so tests never touch real git:

    * `:git_fun` — `(args :: [binary], cwd :: binary) -> {output :: binary, exit :: integer}`
      (mirrors `System.cmd("git", args, ...)`). Defaults to real `git`.
    * `:cmd_fun` — `(command :: binary, cwd :: binary) -> {output :: binary, exit :: integer}`
      runs one gate command. Defaults to splitting the string and calling
      `System.cmd/3`.

  This is the function-seam form of a small `Git` behaviour: any module can be
  adapted by passing `git_fun: &MyGit.run/2`.

  ## Return shape

      %{
        merged: [binary],                     # files brought into the branch
        conflicts: [binary],                  # overlapping files, skipped
        gate: :pass | :fail | :skipped,
        gate_output: binary,
        committed: boolean,
        message: binary                       # human-readable detail
      }

  `finalize/3` never raises — any error becomes a `gate: :fail` result with the
  detail in `:gate_output` / `:message`.
  """

  require Logger

  @type node_result :: %{
          required(:node_id) => binary,
          required(:worktree_ref) => binary | nil,
          required(:files_changed) => [binary],
          required(:gate) => :pass | :fail | :skipped,
          required(:stubbed) => [binary],
          required(:summary) => binary,
          required(:error) => term | nil
        }

  @type git_fun :: ([binary], binary -> {binary, integer})
  @type cmd_fun :: (binary, binary -> {binary, integer})

  @type result :: %{
          merged: [binary],
          conflicts: [binary],
          gate: :pass | :fail | :skipped,
          gate_output: binary,
          committed: boolean,
          message: binary
        }

  @doc """
  Finalize a completed isolated fan-out.

  `parent_session_id` identifies the orchestrating run (used for logging only).
  `node_results` is the list of frozen-contract node maps. `opts`:

    * `:gate_cmds` — list of shell command strings (default `[]` → gate skipped)
    * `:commit`    — commit message; when set (and green + no conflicts) the
                     merge is committed verbatim, attribution-clean
    * `:cwd`       — working directory of the target branch (default `File.cwd!/0`)
    * `:git_fun`   — injectable git runner (see moduledoc)
    * `:cmd_fun`   — injectable gate-command runner (see moduledoc)
  """
  @spec finalize(binary, [node_result], keyword) :: result
  def finalize(parent_session_id, node_results, opts \\ [])
      when is_list(node_results) and is_list(opts) do
    git_fun = Keyword.get(opts, :git_fun, &default_git_fun/2)
    cmd_fun = Keyword.get(opts, :cmd_fun, &default_cmd_fun/2)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    gate_cmds = Keyword.get(opts, :gate_cmds, [])
    commit_msg = Keyword.get(opts, :commit)

    conflicts = detect_conflicts(node_results)

    case merge_nodes(node_results, conflicts, cwd, git_fun) do
      {:ok, merged} ->
        {gate, gate_output} = run_gate(gate_cmds, cwd, cmd_fun)
        # Stage ONLY the files this finalize is responsible for — the merged
        # worktree diffs PLUS the non-conflicting files of non-isolated non-error
        # nodes (whose edits already live in the working tree). A blanket
        # `git add -A` would sweep in unrelated dirty files / secrets under the
        # orchestration commit; scoped staging keeps the commit honest.
        stage_files = staged_files(node_results, merged, conflicts)
        {committed, commit_note} = maybe_commit(commit_msg, conflicts, gate, stage_files, cwd, git_fun)

        result = %{
          merged: merged,
          conflicts: conflicts,
          gate: gate,
          gate_output: gate_output,
          committed: committed,
          message: summarize(parent_session_id, merged, conflicts, gate, committed, commit_note)
        }

        Logger.info(
          "[fleet-finalizer] #{parent_session_id}: merged=#{length(merged)} " <>
            "conflicts=#{length(conflicts)} gate=#{gate} committed=#{committed}"
        )

        result

      {:error, detail} ->
        %{
          merged: [],
          conflicts: conflicts,
          gate: :fail,
          gate_output: detail,
          committed: false,
          message: "merge failed: #{detail}"
        }
    end
  rescue
    e ->
      %{
        merged: [],
        conflicts: [],
        gate: :fail,
        gate_output: Exception.message(e),
        committed: false,
        message: "finalizer error: #{Exception.message(e)}"
      }
  end

  # ── Conflict detection ───────────────────────────────────────────────

  # A file changed by more than one node is an overlap. De-dup within a node
  # first so a node listing the same file twice is not a self-conflict.
  defp detect_conflicts(node_results) do
    node_results
    |> Enum.flat_map(fn node -> node |> files_of() |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_file, count} -> count > 1 end)
    |> Enum.map(fn {file, _count} -> file end)
    |> Enum.sort()
  end

  # ── Merge (disjoint worktree diffs → current branch) ─────────────────

  defp merge_nodes(node_results, conflicts, cwd, git_fun) do
    conflict_set = MapSet.new(conflicts)

    node_results
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      cond do
        node_error?(node) ->
          {:cont, {:ok, acc}}

        is_nil(worktree_ref_of(node)) ->
          # Non-isolated node: its edits already live in the working tree, so
          # there is nothing to check out.
          {:cont, {:ok, acc}}

        true ->
          files =
            node
            |> files_of()
            |> Enum.uniq()
            |> Enum.reject(&MapSet.member?(conflict_set, &1))

          case checkout_files(worktree_ref_of(node), files, cwd, git_fun) do
            {:ok, done} -> {:cont, {:ok, acc ++ done}}
            {:error, out} -> {:halt, {:error, out}}
          end
      end
    end)
    |> case do
      {:ok, merged} -> {:ok, Enum.uniq(merged)}
      other -> other
    end
  end

  defp checkout_files(_ref, [], _cwd, _git_fun), do: {:ok, []}

  defp checkout_files(ref, files, cwd, git_fun) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case git_fun.(["checkout", ref, "--", file], cwd) do
        {_out, 0} -> {:cont, {:ok, acc ++ [file]}}
        {out, _code} -> {:halt, {:error, "checkout #{file} from #{ref}: #{out}"}}
      end
    end)
  end

  # ── Gate ─────────────────────────────────────────────────────────────

  defp run_gate([], _cwd, _cmd_fun), do: {:skipped, ""}

  defp run_gate(cmds, cwd, cmd_fun) do
    Enum.reduce_while(cmds, {:pass, ""}, fn cmd, {_status, acc} ->
      {out, code} = cmd_fun.(cmd, cwd)
      section = "$ #{cmd}\n#{out}"
      new_acc = if acc == "", do: section, else: acc <> "\n" <> section

      if code == 0 do
        {:cont, {:pass, new_acc}}
      else
        {:halt, {:fail, new_acc}}
      end
    end)
  end

  # ── Staging set (scoped — never `git add -A`) ────────────────────────

  # The files this orchestration commit is allowed to stage: the merged worktree
  # diffs UNION the non-conflicting files of non-isolated non-error nodes (their
  # edits are already in the working tree, so they were never checked out into
  # `merged`). Conflicted files are excluded. De-duped + sorted for stable calls.
  defp staged_files(node_results, merged, conflicts) do
    conflict_set = MapSet.new(conflicts)

    non_isolated =
      node_results
      |> Enum.reject(&node_error?/1)
      |> Enum.filter(&is_nil(worktree_ref_of(&1)))
      |> Enum.flat_map(fn node -> node |> files_of() |> Enum.uniq() end)

    (merged ++ non_isolated)
    |> Enum.reject(&MapSet.member?(conflict_set, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── Commit (attribution-clean, never push) ───────────────────────────

  defp maybe_commit(nil, _conflicts, _gate, _files, _cwd, _git_fun),
    do: {false, "no commit requested"}

  defp maybe_commit(_msg, conflicts, _gate, _files, _cwd, _git_fun) when conflicts != [],
    do: {false, "not committed: #{length(conflicts)} conflict(s)"}

  defp maybe_commit(_msg, _conflicts, :fail, _files, _cwd, _git_fun),
    do: {false, "not committed: gate failed"}

  defp maybe_commit(_msg, _conflicts, _gate, [], _cwd, _git_fun),
    do: {false, "not committed: no files to stage"}

  defp maybe_commit(msg, _conflicts, _gate, files, cwd, git_fun) do
    with :ok <- add_files(files, cwd, git_fun),
         # NOTE: message is passed verbatim — NO Co-Authored-By / AI footer is
         # ever appended here. Attribution stays exactly what the caller wrote.
         {_out2, 0} <- git_fun.(["commit", "-m", msg], cwd) do
      {true, "committed"}
    else
      {:error, out} -> {false, "commit failed: #{out}"}
      {out, _code} -> {false, "commit failed: #{out}"}
    end
  end

  # Stage each scoped file individually via a pathspec `git add -- <file>` — never
  # `-A` — so nothing outside the merged/owned set can be swept into the commit.
  defp add_files(files, cwd, git_fun) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case git_fun.(["add", "--", file], cwd) do
        {_out, 0} -> {:cont, :ok}
        {out, _code} -> {:halt, {:error, out}}
      end
    end)
  end

  # ── Summary ──────────────────────────────────────────────────────────

  defp summarize(session_id, merged, conflicts, gate, committed, commit_note) do
    base =
      "finalize(#{session_id}): merged #{length(merged)} file(s), " <>
        "#{length(conflicts)} conflict(s), gate #{gate}, committed #{committed}"

    if conflicts == [], do: "#{base} (#{commit_note})", else: "#{base}; conflicts=#{Enum.join(conflicts, ", ")}"
  end

  # ── Field accessors (tolerant of missing keys) ───────────────────────

  defp files_of(node), do: Map.get(node, :files_changed) || []
  defp worktree_ref_of(node), do: Map.get(node, :worktree_ref)
  defp node_error?(node), do: Map.get(node, :error) != nil

  # ── Default (real) IO seams ──────────────────────────────────────────

  defp default_git_fun(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end

  defp default_cmd_fun(command, cwd) do
    case String.split(command, ~r/\s+/, trim: true) do
      [program | args] -> System.cmd(program, args, cd: cwd, stderr_to_stdout: true)
      [] -> {"empty command", 0}
    end
  end
end
