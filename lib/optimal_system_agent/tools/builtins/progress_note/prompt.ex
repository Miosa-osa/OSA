defmodule OptimalSystemAgent.Tools.Builtins.ProgressNote.Prompt do
  @moduledoc """
  Dynamic prompt for `progress_note`.
  """

  alias OptimalSystemAgent.Tools.Builtins.ProgressNote.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    max = Constants.max_note_chars()

    """
    Record a decision, step, or todo into this session's durable progress
    ledger — a markdown file on disk that survives every context reset.

    Use this every time you make a meaningful move so a coherent trail exists
    even after the conversation is summarised or compacted. Good notes to record:

      - Decisions ("chose approach X over Y because ...")
      - Completed steps ("wrote module Z, tests pass")
      - Open todos ("still need to wire up the registry")
      - Blockers or findings you must not forget across a reset

    Pass a single `note` string. To set (or replace) the overall session goal,
    prefix the note with `goal:` — e.g. `goal: migrate the auth flow to JWT`.
    Everything else is appended as a timestamped bullet to the ledger's log.

    Notes are capped at #{max} characters. This tool is for durable memory, not
    for talking to the user — keep entries terse and factual.
    """
  end
end
