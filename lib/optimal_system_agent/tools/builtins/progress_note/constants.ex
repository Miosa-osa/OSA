defmodule OptimalSystemAgent.Tools.Builtins.ProgressNote.Constants do
  @moduledoc """
  Exported constants for cross-tool references to `progress_note`.

  Other prompts that reference this tool name should use `safe_ref/3` against
  this module so a rename propagates automatically.
  """

  @tool_name "progress_note"
  def tool_name, do: @tool_name

  # Hard cap on the note text accepted from the model (chars). Keeps individual
  # ledger bullets bounded so the ledger stays scannable.
  @max_note_chars 4_000
  def max_note_chars, do: @max_note_chars

  # Hard cap on the confirmation text returned to the model (chars).
  @max_result_size_chars 4_000
  def max_result_size_chars, do: @max_result_size_chars
end
