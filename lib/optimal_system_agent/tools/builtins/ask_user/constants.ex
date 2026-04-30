defmodule OptimalSystemAgent.Tools.Builtins.AskUser.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors `src/tools/AskUserQuestionTool/prompt.ts` constants.
  Other tools can reference `tool_name/0` so a rename propagates everywhere.
  """

  @tool_name "ask_user"
  def tool_name, do: @tool_name

  @timeout_ms 300_000
  def timeout_ms, do: @timeout_ms

  @pending_questions_table :osa_pending_questions
  def pending_questions_table, do: @pending_questions_table
end
