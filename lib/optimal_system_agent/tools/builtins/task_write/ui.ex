defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `FileRead.UI` in structure. Each `render/3` call returns a
  structured map that the TUI consumes over the existing PubSub event
  channel — the TUI side maps `kind` to the `TodosRenderer` component.

  ## Frontend contract (`priv/rust/tui/src/tools/todos.rs`)

  `todos.rs::parse_todos` accepts either:

  1. A JSON array of objects with `content`/`text`/`description`/`task`
     and `status`/`state` fields.
  2. A JSON object `{ "todos": [...] }` with the same item shape.
  3. A plain-text fallback parsed by `parse_plain_todos` (markdown
     checklist: `- [ ]`, `- [x]`, `- [>]`, `- [!]`).

  The `:tool_result` render path returns shape (2): a JSON-encoded
  `{ "todos": [...] }` string as `result_json`, plus the structured
  `tasks` list for any Elixir-side consumer that wants atoms. The
  `result_json` field is what the TUI renders when it passes the result
  string to `parse_todos`.

  For the `:tool_use` stage (before execution) we emit a lightweight
  map so the TUI can show a spinner with the action name.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — execution succeeded; payload is the plain-text result
    * `:rejected`    — user denied (unused today; reserved for Phase 4 ask)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "task_write",
      action: action,
      session_id: input["session_id"],
      task_id: input["task_id"],
      title: input["title"]
    }
  end

  def render(:tool_use, input, _opts) when is_map(input) do
    %{kind: "task_write", action: nil}
  end

  # `:tool_result` payload is the plain-text string returned by Handler.execute/2.
  # We serialise the task structs into the `{ "todos": [...] }` JSON shape
  # that todos.rs::parse_todos expects, and include the raw text as a
  # fallback.
  def render(:tool_result, result_text, opts) when is_binary(result_text) do
    tasks = Keyword.get(opts, :tasks, [])

    todo_items =
      Enum.map(tasks, fn task ->
        %{
          "content" => task.title,
          "status" => task_status_string(task.status),
          "id" => task.id
        }
      end)

    # Encode the JSON that todos.rs will parse via parse_todos.
    result_json =
      case Jason.encode(%{"todos" => todo_items}) do
        {:ok, json} -> json
        {:error, _} -> result_text
      end

    %{
      kind: "task_write_result",
      result_json: result_json,
      tasks: tasks,
      summary: result_text
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "task_write_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "task_write_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  # ── Private ────────────────────────────────────────────────────────────

  defp task_status_string(:completed), do: "completed"
  defp task_status_string(:in_progress), do: "in_progress"
  defp task_status_string(:failed), do: "failed"
  defp task_status_string(_), do: "pending"
end
