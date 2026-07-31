defmodule OptimalSystemAgent.Agent.CompactRestore do
  @moduledoc """
  Post-compaction context restoration.

  After context compaction, critical working state is re-injected as a
  system message so the agent maintains awareness of its environment.
  Restores: files touched, top file CONTENTS (5k per-file / 50k total char
  budgets), active tasks, workspace info, and active skills.
  """
  require Logger

  @doc """
  Build a restoration message containing current working context.
  Returns a system message map or nil if no context to restore.
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

      %{role: "system", content: content}
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
          subject = Map.get(task, :subject, "?")

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
