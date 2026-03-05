defmodule OptimalSystemAgent.Commands.Data do
  @moduledoc """
  Data commands: export, tasks.
  """

  @doc "Handle the `/export` command."
  def cmd_export(arg, session_id) do
    trimmed = String.trim(arg)

    filename =
      if trimmed == "" do
        timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
        "osa_session_#{timestamp}.md"
      else
        trimmed
      end

    try do
      messages = OptimalSystemAgent.Agent.Memory.load_session(session_id)

      if messages == [] or is_nil(messages) do
        {:command, "No messages in current session to export."}
      else
        content =
          [
            "# OSA Session Export",
            "Session: #{session_id}",
            "Exported: #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")}",
            "Messages: #{length(messages)}",
            "",
            "---",
            ""
            | Enum.map(messages, fn msg ->
                role = msg[:role] || msg["role"] || "unknown"
                text = msg[:content] || msg["content"] || ""
                "## #{String.capitalize(to_string(role))}\n\n#{text}\n"
              end)
          ]
          |> Enum.join("\n")

        path = Path.expand(filename)
        File.write!(path, content)

        {:command, "Session exported to: #{path}\n  Messages: #{length(messages)}"}
      end
    rescue
      e -> {:command, "Export failed: #{Exception.message(e)}"}
    end
  end

  @doc "Handle the `/tasks` command."
  def cmd_tasks(arg, session_id) do
    alias OptimalSystemAgent.Agent.TaskTracker
    alias OptimalSystemAgent.Channels.CLI.TaskDisplay
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        tasks = TaskTracker.get_tasks(session_id)

        if tasks == [] do
          {:command, "No tracked tasks. Use /tasks add \"title\" or let OSA auto-detect."}
        else
          {:command, TaskDisplay.render(tasks)}
        end

      trimmed == "clear" ->
        TaskTracker.clear_tasks(session_id)
        {:command, "Tasks cleared."}

      trimmed == "compact" ->
        tasks = TaskTracker.get_tasks(session_id)
        if tasks == [], do: {:command, "No tasks."}, else: {:command, TaskDisplay.render_compact(tasks)}

      trimmed == "inline" ->
        tasks = TaskTracker.get_tasks(session_id)
        if tasks == [], do: {:command, "No tasks."}, else: {:command, TaskDisplay.render_inline(tasks)}

      String.starts_with?(trimmed, "add ") ->
        title = trimmed |> String.replace_prefix("add ", "") |> String.trim() |> String.trim("\"")

        if title == "" do
          {:command, "Usage: /tasks add \"title\""}
        else
          {:ok, id} = TaskTracker.add_task(session_id, title)
          {:command, "Added task #{id}: #{title}"}
        end

      true ->
        {:command,
         "Unknown subcommand: #{trimmed}\n\nUsage:\n  /tasks           — show task panel\n  /tasks add \"t\"   — add a task\n  /tasks clear     — clear all tasks\n  /tasks compact   — single-line view\n  /tasks inline    — Claude Code-style view"}
    end
  rescue
    _ -> {:command, "Task tracker not available."}
  end
end
