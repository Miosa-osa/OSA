defmodule OptimalSystemAgent.Agent.Reminders do
  @moduledoc """
  Cross-cutting `<system-reminder>` pipeline for tool observations.

  After every tool call completes, `append/3` folds any *contextual* hints —
  wrapped in `<system-reminder>` tags — onto the tool result the model sees.
  This is the OSA analogue of grok-build's `src/reminders/` crate and
  opencode's post-read `<system-reminder>` injection: steering the model
  without polluting the system prompt and without the model having to poll.

  Three collectors run, in order, and their outputs are concatenated:

    1. **task-completion** — background shell commands
       (`Shell.BackgroundManager`) and background subagents (`Agent.RunStore`)
       that reached a terminal state and belong to this session. Surfaces
       "Background command … completed" so the model reacts on its NEXT turn
       instead of polling `bash_output` / `task_output`. Cross-surface
       exactly-once is enforced via `Agent.TaskNotifications.mark_notified/1`,
       the same check-and-set the idle-loop notifier uses — so a completion is
       delivered by whichever surface (this reminder or the notifier's
       queue+poke) reaches it first, never both.

    2. **skill-discovery** — a `SKILL.md` living in a `.osa/skills/`,
       `.claude/skills/`, `.agents/skills/`, `.grok/skills/`, or
       `.cursor/skills/` directory at/above the path a filesystem tool just
       touched. Announces the skill once so the model can opt into it.

    3. **diagnostics** — post-edit diagnostics for the edited file, IF a
       provider is configured (`:optimal_system_agent, :diagnostics_provider`).
       OSA ships no LSP backend, so this is a no-op by default and a clean
       extension point; it never blocks and never fabricates output.

  ## Dedup

  Every candidate reminder has a stable *claim key*. Keys are recorded per
  session in the `:osa_reminders_claimed` ETS set via `:ets.insert_new/2`, so
  the identical reminder is emitted AT MOST ONCE per session — it is not
  repeated on every subsequent tool call.

  ## Non-fatal

  The whole pipeline is wrapped so that any failure (a crashed collector, a
  missing ETS table, a slow `GenServer.call`) returns the tool result
  UNCHANGED. A reminder is a nicety; it must never break a tool observation.
  """

  require Logger

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.TaskNotifications
  alias OptimalSystemAgent.Shell.BackgroundManager

  @claims_table :osa_reminders_claimed
  @tag "system-reminder"

  # Directory names (parents of a `skills/` dir) that hold skill definitions.
  @skill_config_dirs ~w(.osa .claude .agents .grok .cursor)

  # Filesystem tools whose "path" argument identifies a touched path for
  # skill-discovery. Read/write/edit/list — anything else has no reliable path.
  @path_tools ~w(
    file_read read_file file_write file_create file_edit multi_file_edit
    dir_list list_dir notebook_edit
  )

  # Ancestor-walk bound: never climb more than this many directories looking
  # for a skills/ dir (defends against a path far outside the workspace).
  @max_walk_depth 40

  # Cap a subagent result preview so a chatty agent can't blow up the reminder.
  @subagent_preview_bytes 600

  @doc """
  Append any relevant `<system-reminder>` block(s) to `result_str` for the
  just-finished `tool_call`. Returns `result_str` unchanged when there is
  nothing to surface (or on any error — the pipeline is non-fatal).
  """
  @spec append(String.t(), map(), map()) :: String.t()
  def append(result_str, tool_call, state) when is_binary(result_str) do
    session_id = Map.get(state, :session_id) || "default"

    reminders =
      collect_task_completions(session_id) ++
        collect_skill_discovery(session_id, tool_call, state) ++
        collect_diagnostics(tool_call, state)

    format_with_reminders(result_str, reminders)
  rescue
    e ->
      Logger.debug("[reminders] append failed (non-fatal): #{Exception.message(e)}")
      result_str
  catch
    :exit, reason ->
      Logger.debug("[reminders] append exited (non-fatal): #{inspect(reason)}")
      result_str
  end

  def append(result_str, _tool_call, _state), do: result_str

  @doc """
  Wrap each reminder string in `<system-reminder>` tags and append the block to
  `output`. Returns `output` unchanged when `reminders` is empty. Public for
  testing and reuse.
  """
  @spec format_with_reminders(String.t(), [String.t()]) :: String.t()
  def format_with_reminders(output, []), do: output

  def format_with_reminders(output, reminders) when is_list(reminders) do
    joined =
      reminders
      |> Enum.map(&"<#{@tag}>\n#{&1}\n</#{@tag}>")
      |> Enum.join("\n\n")

    if output == "", do: joined, else: output <> "\n\n" <> joined
  end

  # ── Collector 1: task completion ─────────────────────────────────────────

  defp collect_task_completions(session_id) do
    collect_bg_completions(session_id) ++ collect_subagent_completions(session_id)
  end

  defp collect_bg_completions(session_id) do
    BackgroundManager.list()
    |> Enum.filter(fn snap ->
      snap[:session_id] == session_id and terminal_bg_status?(snap[:status])
    end)
    |> Enum.filter(fn snap -> claim(session_id, {:bgtask, snap[:id]}) end)
    # Cross-surface exactly-once: only surface if this reminder is the first to
    # claim the id (the idle-loop notifier consumes the same flag).
    |> Enum.filter(fn snap -> notify_gate(snap[:id]) end)
    |> Enum.map(&format_bg_completion/1)
  rescue
    _ -> []
  end

  defp collect_subagent_completions(session_id) do
    RunStore.list(limit: 50)
    |> Enum.filter(fn run ->
      run.parent_session_id == session_id and run.status in [:completed, :failed, :cancelled]
    end)
    |> Enum.filter(fn run -> claim(session_id, {:subagent, run.agent_id}) end)
    |> Enum.filter(fn run -> notify_gate(run.agent_id) end)
    |> Enum.map(&format_subagent_completion/1)
  rescue
    _ -> []
  end

  defp terminal_bg_status?(status), do: status in [:done, :failed, :killed]

  defp format_bg_completion(snap) do
    verb =
      case snap[:status] do
        :killed -> "was stopped"
        :failed -> "failed"
        _ -> "completed"
      end

    code =
      case snap[:exit_code] do
        c when is_integer(c) -> " (exit code #{c})"
        _ -> ""
      end

    file =
      case snap[:output_file] do
        f when is_binary(f) and f != "" ->
          " Full output is in #{f} (read it with the read tool)."

        _ ->
          ""
      end

    "Background command #{quote_cmd(snap[:command])} #{verb}#{code}." <>
      file <> " Do not poll for this task again."
  end

  defp format_subagent_completion(run) do
    role = to_string(run.role || "agent")
    dur = if is_integer(run.duration_ms), do: " after #{run.duration_ms}ms", else: ""

    status_word =
      case run.status do
        :completed -> "completed"
        :failed -> "failed"
        :cancelled -> "was cancelled"
        other -> to_string(other)
      end

    preview =
      run.result
      |> subagent_result_text()
      |> String.slice(0, @subagent_preview_bytes)

    tail = if preview == "", do: "", else: "\nResult: #{preview}"

    "Background subagent #{quote_cmd(role)} (#{run.agent_id}) #{status_word}#{dur}." <>
      tail <> "\nDo not poll for this subagent again."
  end

  defp subagent_result_text(%{summary: s}) when is_binary(s), do: s
  defp subagent_result_text(%{result: r}) when is_binary(r), do: r
  defp subagent_result_text(%{output: o}) when is_binary(o), do: o
  defp subagent_result_text(r) when is_binary(r), do: r
  defp subagent_result_text(_), do: ""

  defp quote_cmd(nil), do: "\"\""
  defp quote_cmd(cmd) when is_binary(cmd), do: "\"" <> String.slice(cmd, 0, 120) <> "\""
  defp quote_cmd(other), do: "\"" <> (other |> to_string() |> String.slice(0, 120)) <> "\""

  # Consult the shared exactly-once "notified" flag. `mark_notified/1` returns
  # true exactly once per id across the whole system. A blank id can't be
  # arbitrated, so it always surfaces (dedup still covers it via `claim/2`).
  defp notify_gate(id) do
    case to_string(id || "") do
      "" -> true
      s -> TaskNotifications.mark_notified(s)
    end
  rescue
    _ -> true
  end

  # ── Collector 2: skill discovery ─────────────────────────────────────────

  defp collect_skill_discovery(session_id, tool_call, state) do
    with path when is_binary(path) <- touched_path(tool_call),
         abs <- Path.expand(path) do
      root = working_dir(state)

      abs
      |> discover_skill_files(root)
      |> Enum.filter(fn skill_path -> claim(session_id, {:skill, skill_path}) end)
      |> Enum.map(&format_skill_reminder/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # The path a filesystem tool operated on, or nil for non-path tools.
  defp touched_path(tool_call) do
    name = Map.get(tool_call, :name)
    args = Map.get(tool_call, :arguments) || %{}

    if name in @path_tools do
      case Map.get(args, "path") || Map.get(args, "file_path") do
        p when is_binary(p) and p != "" -> p
        _ -> nil
      end
    end
  end

  # Find SKILL.md files reachable from `abs`: the file itself if it IS a
  # SKILL.md in a skills dir, plus any `<skillsdir>/*/SKILL.md` at each ancestor
  # up to (and including) `root`.
  defp discover_skill_files(abs, root) do
    start_dir = if File.dir?(abs), do: abs, else: Path.dirname(abs)

    direct =
      if Path.basename(abs) == "SKILL.md" and in_skills_dir?(abs),
        do: [abs],
        else: []

    walked = ancestors(start_dir, root) |> Enum.flat_map(&skill_files_in_dir/1)

    (direct ++ walked)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  # Directories from `dir` up to `root` (inclusive), bounded by @max_walk_depth.
  # When `root` is nil or not an ancestor, walk a bounded number of levels.
  defp ancestors(dir, root) do
    Enum.reduce_while(1..@max_walk_depth, {dir, []}, fn _i, {current, acc} ->
      acc = [current | acc]
      parent = Path.dirname(current)

      cond do
        is_binary(root) and current == root -> {:halt, acc}
        parent == current -> {:halt, acc}
        true -> {:cont, {parent, acc}}
      end
    end)
    |> case do
      {_current, acc} -> Enum.reverse(acc)
      acc when is_list(acc) -> Enum.reverse(acc)
    end
  end

  # `<dir>/<cfg>/skills/*/SKILL.md` for each configured cfg dir under `dir`.
  defp skill_files_in_dir(dir) do
    Enum.flat_map(@skill_config_dirs, fn cfg ->
      skills_root = Path.join([dir, cfg, "skills"])

      case File.ls(skills_root) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join([skills_root, &1, "SKILL.md"]))
          |> Enum.filter(&File.regular?/1)

        _ ->
          []
      end
    end)
  end

  # True when `path` sits inside a `<cfg>/skills/` directory.
  defp in_skills_dir?(path) do
    parts = Path.split(Path.dirname(path))

    Enum.any?(0..(length(parts) - 2)//1, fn i ->
      Enum.at(parts, i) in @skill_config_dirs and Enum.at(parts, i + 1) == "skills"
    end)
  rescue
    _ -> false
  end

  defp format_skill_reminder(skill_path) do
    name =
      skill_path
      |> Path.dirname()
      |> Path.basename()

    desc = skill_description(skill_path)
    tail = if desc == "", do: "", else: " — #{desc}"

    "A skill \"#{name}\" is available near a path you just accessed" <>
      tail <>
      ".\nIts definition is at #{skill_path}; read it with the read tool if it is relevant to the task."
  end

  # Best-effort one-line description from the SKILL.md front-matter/first line.
  defp skill_description(skill_path) do
    case File.read(skill_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: false)
        |> Enum.find_value("", fn line ->
          cond do
            Regex.match?(~r/^\s*description\s*:/i, line) ->
              line |> String.replace(~r/^\s*description\s*:/i, "") |> String.trim()

            true ->
              nil
          end
        end)
        |> String.slice(0, 200)

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  # ── Collector 3: post-edit diagnostics (pluggable, no-op by default) ──────

  defp collect_diagnostics(tool_call, state) do
    name = Map.get(tool_call, :name)

    with true <- name in ~w(file_edit multi_file_edit file_write file_create),
         provider when not is_nil(provider) <-
           Application.get_env(:optimal_system_agent, :diagnostics_provider),
         path when is_binary(path) <- touched_path(tool_call),
         summary when is_binary(summary) and summary != "" <-
           run_diagnostics_provider(provider, Path.expand(path), state) do
      ["Diagnostics for #{path}:\n#{String.slice(summary, 0, 2000)}"]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp run_diagnostics_provider(fun, path, state) when is_function(fun, 2),
    do: fun.(path, state)

  defp run_diagnostics_provider(fun, path, _state) when is_function(fun, 1),
    do: fun.(path)

  defp run_diagnostics_provider({mod, fun}, path, state),
    do: apply(mod, fun, [path, state])

  defp run_diagnostics_provider(_, _path, _state), do: nil

  # ── Dedup + helpers ──────────────────────────────────────────────────────

  # Record a claim key for `session_id`. Returns true the FIRST time the key is
  # seen this session (surface the reminder), false thereafter (suppress it).
  @doc false
  @spec claim(String.t(), term()) :: boolean()
  def claim(session_id, key) do
    ensure_table()
    :ets.insert_new(@claims_table, {{session_id, key}, true})
  rescue
    _ -> true
  end

  defp working_dir(state) do
    Map.get(state, :working_dir) ||
      try do
        OptimalSystemAgent.Workspace.Cwd.get()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
  end

  defp ensure_table do
    case :ets.whereis(@claims_table) do
      :undefined ->
        :ets.new(@claims_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
