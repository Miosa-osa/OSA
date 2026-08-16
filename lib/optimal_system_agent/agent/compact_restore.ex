defmodule OptimalSystemAgent.Agent.CompactRestore do
  @moduledoc """
  Post-compaction context restoration.

  After context compaction, critical working state is re-injected as a
  system message so the agent maintains awareness of its environment.
  Restores: files touched, top file CONTENTS (5k per-file / 50k total char
  budgets), active tasks, workspace info, and active skills.
  """
  require Logger

  # The restore block re-injects up to 50k characters of file bodies, which is
  # ~12.5k tokens on its own and was measured at 65,004 tokens in the field. The
  # bound belongs HERE, on the builder, not on the callers: `ProactiveCompaction`
  # clamped it and `Compactor` -- the path behind `/compact` and the prune tier --
  # appended it raw, so the same block was bounded on one compaction path and
  # unbounded on its sibling. A live v1.0.101 session recorded the result:
  #
  #     Compacted ~6.1k -> ~71.8k tokens (1 messages folded)
  #
  # i.e. compaction inflating the window ~12x, then re-firing because the fold
  # had pushed the total past the very threshold that triggers folding.
  #
  # Clamping at the source means a future caller cannot reintroduce it by
  # forgetting; the caller-side clamp in `ProactiveCompaction` is left in place
  # and is now idempotent.
  @default_max_tokens 4_000

  defp max_tokens do
    case Application.get_env(
           :optimal_system_agent,
           :compaction_restore_max_tokens,
           @default_max_tokens
         ) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_tokens
    end
  end

  @truncation_notice "\n\n[Restore context truncated to fit the compacted window.]"

  defp clamp(%{content: content} = msg) when is_binary(content) do
    max = max_tokens()

    if OptimalSystemAgent.Agent.Compactor.estimate_tokens([msg]) <= max do
      msg
    else
      # Budget the notice and the per-message overhead BEFORE slicing. Slicing to
      # `max * 4` and then appending overshoots — measured 4,019 against a 4,000
      # ceiling, and 519 against 500. A bound that is exceeded by the very text
      # it appends is the same defect one scale down, and on this path the
      # overshoot lands in a window that was just compacted.
      notice_chars = String.length(@truncation_notice)
      overhead_chars = 32
      budget = max(max * 4 - notice_chars - overhead_chars, 0)

      %{msg | content: String.slice(content, 0, budget) <> @truncation_notice}
    end
  end

  defp clamp(msg), do: msg

  @doc false
  # Exposed so the invariant can be asserted on the clamp itself rather than
  # through a session fixture — the defect was that one caller skipped it, so
  # the test must not reach it through a caller.
  def clamp_for_test(msg), do: clamp(msg)

  @doc """
  Build a restoration message containing current working context.
  Returns a system message map or nil if no context to restore.

  The returned block is clamped to `:compaction_restore_max_tokens` (default
  4,000) so it can never re-inflate a freshly compacted window.
  """
  def build_restore_message(session_id) do
    sections =
      [
        files_section(session_id),
        file_contents_section(session_id),
        tasks_section(session_id),
        workspace_section(),
        skills_section()
      ]
      |> Enum.reject(&is_nil/1)

    if sections == [] do
      nil
    else
      content =
        "[Post-compaction context restore — the conversation was compacted to save space. " <>
          "Here is your current working context:]\n\n" <>
          Enum.join(sections, "\n\n")

      clamp(%{role: "system", content: content})
    end
  rescue
    e ->
      Logger.debug("[compact_restore] Failed to build restore message: #{inspect(e)}")
      nil
  end

  # ── Files recently read/modified ────────────────────────────────────

  defp files_section(session_id) do
    files =
      try do
        :ets.match(:osa_files_read, {{session_id, :"$1"}, :_})
        |> Enum.map(fn [path] -> path end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(20)
      rescue
        _ -> []
      end

    if files == [] do
      nil
    else
      file_list = Enum.map(files, fn f -> "- `#{f}`" end) |> Enum.join("\n")
      "## Files Touched This Session\n#{file_list}"
    end
  end

  # ── Top file CONTENTS re-injected after compaction ──────────────────
  #
  # The agent has lost the bodies of the files it was editing. Re-read up to
  # 5 session files within per-file/total character budgets so post-compact
  # recall covers actual content, not just paths (CC sessionRestore parity).

  @file_content_budget 5_000
  @total_content_budget 50_000
  @max_files_restored 5

  defp file_contents_section(session_id) do
    files =
      try do
        :ets.match(:osa_files_read, {{session_id, :"$1"}, :_})
        |> Enum.map(fn [path] -> path end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.take(@max_files_restored)
      rescue
        _ -> []
      end

    {blocks, _used} =
      Enum.reduce(files, {[], 0}, fn path, {acc, used} ->
        if used >= @total_content_budget do
          {acc, used}
        else
          case safe_read(path) do
            nil ->
              {acc, used}

            content ->
              budget = min(@file_content_budget, @total_content_budget - used)
              {snippet, truncated} = clamp(content, budget)
              suffix = if truncated, do: "\n… (truncated)", else: ""
              block = "### `#{path}`\n```\n#{snippet}#{suffix}\n```"
              {[block | acc], used + String.length(snippet)}
          end
        end
      end)

    case blocks do
      [] ->
        nil

      _ ->
        "## File Contents (recently read/modified)\n" <>
          Enum.join(Enum.reverse(blocks), "\n\n")
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content), do: content, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp clamp(content, budget) do
    if String.length(content) > budget do
      {String.slice(content, 0, budget), true}
    else
      {content, false}
    end
  end

  # ── Current task list ───────────────────────────────────────────────

  defp tasks_section(session_id) do
    tasks =
      try do
        OptimalSystemAgent.Agent.Tasks.get_tasks(session_id)
      rescue
        _ -> []
      end

    if is_list(tasks) and length(tasks) > 0 do
      task_list =
        Enum.map(tasks, fn task ->
          status = Map.get(task, :status, :pending)
          subject = task_subject(task)

          icon =
            case status do
              :completed -> "[x]"
              :in_progress -> "[~]"
              :failed -> "[!]"
              _ -> "[ ]"
            end

          "- #{icon} #{subject}"
        end)
        |> Enum.join("\n")

      "## Active Tasks\n#{task_list}"
    else
      nil
    end
  end

  @doc """
  The human-readable name of a task, from whichever shape it arrives in.

  `Agent.Tasks.get_tasks/1` returns `%Tasks.Tracker.Task{}` structs, whose name
  field is `:title`. This function read `:subject` — the key used by the
  Bus/SSE *event* payloads (`Tracker.serialize_task/1`), never by the struct —
  and defaulted to `"?"`. So the post-compaction restore has been re-injecting
  the plan as a column of question marks:

      ## Active Tasks
      - [ ] ?
      - [ ] ?

  Structurally present, semantically empty: the checklist survived the fold and
  said nothing about what the agent was doing, which is precisely the "where was
  I" signal a continuation depends on. Both spellings are accepted so either
  shape works, and an unnamed task is now labelled as unnamed rather than
  silently rendered as one.
  """
  @spec task_subject(map()) :: String.t()
  def task_subject(task) when is_map(task) do
    [:title, :subject, "title", "subject"]
    |> Enum.find_value(fn key ->
      case Map.get(task, key) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
    |> case do
      nil -> "(unnamed task)"
      name -> name
    end
  end

  def task_subject(_), do: "(unnamed task)"

  # ── Current workspace ───────────────────────────────────────────────

  defp workspace_section do
    cwd = File.cwd!()
    branch = git_branch()

    parts = ["## Workspace", "- Directory: `#{cwd}`"]
    parts = if branch, do: parts ++ ["- Git branch: `#{branch}`"], else: parts

    Enum.join(parts, "\n")
  rescue
    _ -> nil
  end

  defp git_branch do
    case OptimalSystemAgent.Git.cmd(["branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Active skills ───────────────────────────────────────────────────

  defp skills_section do
    skills =
      try do
        OptimalSystemAgent.Tools.Registry.list_skills()
      rescue
        _ -> []
      end

    if is_list(skills) and length(skills) > 0 do
      skill_names =
        skills
        |> Enum.map(fn s -> Map.get(s, :name, "?") end)
        |> Enum.take(10)
        |> Enum.join(", ")

      "## Available Skills\n#{skill_names}"
    else
      nil
    end
  end
end
