defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Prompt do
  @moduledoc """
  Dynamic prompt for `task_write`.

  Mirrors the state machine semantics of the `TodoWriteTool/prompt.ts`.
  The prose is a function so it can reference live tool names from sibling
  Constants modules via the `safe_ref/3` helper.

  The state machine itself lives on the `action` parameter, not here: it is a
  contract on the value being composed, and the schema already enumerates the
  actions it constrains. What is left in the description is when to reach for the
  board at all, and the one thing a model reliably gets wrong — narrating a board
  that already renders itself.
  """

  @doc """
  Render the task_write tool prompt.

  `opts` is reserved for future signal-aware customization (e.g., compact
  mode that strips the examples section for narrow context windows).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_edit_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileEdit.Constants,
        :tool_name,
        "file_edit"
      )

    """
    Create and manage the session's task board, so the user sees your plan and
    real-time progress.

    Use it for work needing 3+ distinct steps, when the user gives several tasks
    or asks for a list, and to capture new instructions as they arrive. Skip it
    for a single straightforward task or a conversational question — for one edit
    in one place, just call #{file_edit_name}. When in doubt, use it.

    The board renders itself: after a mutating call do NOT restate the plan, list
    the tasks or narrate the status change, just continue with the work.
    """
  end

  # Lazy cross-tool name reference. Mirrors the pattern in `FileRead.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
