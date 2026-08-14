defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Prompt do
  @moduledoc """
  Dynamic prompt for `task_write`.

  Mirrors the state machine semantics of the `TodoWriteTool/prompt.ts`.
  The prose is a function so it can reference live tool names from sibling
  Constants modules via the `safe_ref/3` helper.
  """

  alias OptimalSystemAgent.Tools.Builtins.TaskWrite.Constants

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

    Use it proactively for work needing 3+ distinct steps, for careful planning,
    when the user asks for a list or gives several tasks, and to capture new
    instructions as they arrive. Skip it for a single straightforward task, work
    under 3 steps, or a purely conversational question — a one-step plan is pure
    latency. When in doubt, use it.

    States: `pending` → `in_progress` → `completed` (or `failed`).
    - EXACTLY ONE task `in_progress` while work is underway — not less, not more.
    - Mark `in_progress` BEFORE starting, never after.
    - Mark `completed` only when fully accomplished, with evidence. NEVER when
      tests fail, the implementation is partial, or errors are unresolved.
    - If blocked, keep it `in_progress` and add a new task describing the blocker.

    Actions: `add` / `add_multiple` to create, `start`, `complete`, `fail` (with a
    reason), `update` (revise without changing status), `add_dependency` /
    `remove_dependency` for ordering, `next` for the next unblocked task, `list`,
    and `clear` (sparingly).

    The board renders itself. After any mutating call do NOT restate the plan, list
    the tasks, or narrate the status change — it is already on screen. Just continue
    with the work. For a single edit in one place, use #{file_edit_name} directly.

    A status update is bookkeeping, not work. Send it in the SAME turn as the tool
    call that does the next step — a turn whose only call is #{Constants.tool_name()}
    moved nothing and cost a full round-trip through your context. The one exception
    is the opening `add_multiple` that creates the board before any work exists.
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
