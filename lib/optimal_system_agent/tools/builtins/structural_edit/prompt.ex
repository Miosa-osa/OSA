defmodule OptimalSystemAgent.Tools.Builtins.StructuralEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `structural_edit`.

  Written to route the model AWAY from hand-rolled cross-file regex sweeps
  (`sed`/`python -c` over N files) — the exact failure mode that motivated this
  tool: a free-form sweep broke four auth files in a live run because it had no
  anchor-uniqueness guarantee and no per-file report of what it actually did.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    multi_edit_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Constants,
        :tool_name,
        "multi_file_edit"
      )

    file_edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    """
    Safely rename or replace an exact snippet across MANY files as one atomic,
    reported operation — for "rename X to Y in these N files" or "change this
    exact snippet everywhere" instead of a shell regex sweep.

    Two input shapes, usable together:
      * `pattern`: ONE `old_string` -> `new_string` applied to every file in
        `paths` — say the intent once instead of repeating identical text per
        file.
      * `edits`: a heterogeneous list, one `old_string`/`new_string` per file,
        for when each target's replacement genuinely differs (same shape as
        `#{multi_edit_name}`).

    Matching is ANCHORED and EXACT (the same cascade `#{file_edit_name}` uses) —
    never free-form regex. A file whose anchor is missing or matches more than
    once is reported as `no_match` / `conflict` and is NEVER guessed at or
    partially applied.

    All-or-reports: every target is validated first. If every one resolves
    cleanly, all files are written together; if even one does not, NOTHING is
    written, and the result lists every target's outcome — applied, no_match,
    conflict, missing, or already_applied — so you can fix exactly the one that
    failed and reissue instead of re-doing the whole batch.

    Set `verify: true` to run a fast in-process syntax/format check on every
    touched file after applying and get the diagnostics back in the same result
    (advisory only — a successful apply is never rolled back because of it).

    Prefer `#{multi_edit_name}` when there is no shared pattern at all. Prefer
    `#{file_edit_name}` for a single file.
    """
  end

  # Lazy cross-tool name reference — mirrors `MultiFileEdit.Prompt` /
  # `FileEdit.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
