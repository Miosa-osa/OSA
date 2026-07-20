defmodule OptimalSystemAgent.Tools.Builtins.Scratchpad.Prompt do
  @moduledoc """
  Dynamic prompt for `scratchpad`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Shared, file-based scratchpad for coordinating with your teammates.

    Unlike your private notes, this is a REAL directory shared by a coordinator
    and every worker it spawns: findings, plans, and partial results you write
    here are readable by your parent and your sibling agents (and survive a
    restart — an operator can inspect them on disk). Use it to hand off work,
    publish a plan, or leave results the coordinator will reconcile.

    Actions:
    - `write`  — create or overwrite an entry (a file) with `content`
    - `append` — append `content` to an entry, creating it if absent
    - `read`   — read an entry by `name`
    - `list`   — list all entries with sizes and modification times
    - `delete` — remove an entry

    Params:
    - `action` (required) — one of the above
    - `name`   — entry name (required for write/append/read/delete). A relative
      filename only, e.g. `findings.md`. Absolute paths, `~`, and `..` are
      rejected — everything stays inside the shared scratchpad directory.
    - `content` — text for write/append.

    Coordination tips:
    - Drop findings under a clear `name` (e.g. `explorer-findings.md`) so the
      coordinator and siblings can `read` them by name.
    - `list` first to see what teammates have already published.
    """
  end
end
