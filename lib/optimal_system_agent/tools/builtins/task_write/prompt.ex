defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Prompt do
  @moduledoc """
  Dynamic prompt for `task_write`.

  Mirrors the state machine semantics of the `TodoWriteTool/prompt.ts`.
  The prose is a function so it can reference live tool names from sibling
  Constants modules via the `safe_ref/3` helper.
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
    Use this tool to create and manage a structured task list for your current
    session. This helps you track progress, organise complex tasks, and
    demonstrate thoroughness to the user. It also lets the user see your
    overall plan and real-time progress.

    ## When to Use This Tool

    Use this tool proactively in these scenarios:

    1. Complex multi-step tasks — when a task requires 3 or more distinct steps
    2. Non-trivial tasks — tasks requiring careful planning or multiple operations
    3. User explicitly requests a todo list
    4. User provides multiple tasks (numbered or comma-separated)
    5. After receiving new instructions — capture requirements as tasks immediately
    6. When starting work — mark the task `in_progress` BEFORE beginning. Only
       ONE task should be `in_progress` at a time.
    7. After completing work — mark as `completed` and add follow-up tasks if
       discovered during implementation.

    ## When NOT to Use This Tool

    Skip it when:
    - There is only a single, straightforward task
    - The task is trivial and can be completed in fewer than 3 steps
    - The task is purely conversational or informational

    ## Task State Machine

    States: `pending` → `in_progress` → `completed` (or `failed`)

    Rules:
    - Exactly ONE task `in_progress` at a time (not less, not more)
    - Mark `in_progress` BEFORE starting — never after
    - Mark `completed` ONLY when fully accomplished with evidence
    - If blocked or erroring, keep as `in_progress` and create a new task
      describing the blocker
    - NEVER mark `completed` if tests are failing, the implementation is
      partial, or errors are unresolved

    ## Task Management

    - `add` / `add_multiple` — create tasks at the start of a plan
    - `start` — transition `pending` → `in_progress` (do this first)
    - `complete` — transition `in_progress` → `completed` (only with evidence)
    - `fail` — record a blocking failure with a reason
    - `update` — revise description/owner/metadata without changing status
    - `add_dependency` / `remove_dependency` — express task ordering
    - `next` — ask the system for the next unblocked `pending` task
    - `list` — inspect the current task board
    - `clear` — wipe the board (use sparingly)

    ## Examples of When to Use

    User: "Add dark mode to the settings page, run tests when done."
    → Create tasks: add toggle component, add state management, update CSS,
      run tests. Start the first task immediately.

    User: "Rename getCwd to getCurrentWorkingDirectory everywhere."
    → Search first to find scope, then create one task per file that needs
      updating.

    ## Examples of When NOT to Use

    User: "How do I print Hello World in Python?"
    → Single informational question — answer directly, no task list needed.

    User: "Add a comment to the #{file_edit_name} function."
    → Single edit in one location — use #{file_edit_name} directly.

    When in doubt, use this tool. Proactive task management demonstrates
    attentiveness and ensures you complete all requirements successfully.
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
