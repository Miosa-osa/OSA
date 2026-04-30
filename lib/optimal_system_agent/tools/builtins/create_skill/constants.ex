defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename here
  propagates automatically across all prompt strings.
  """

  @tool_name "create_skill"
  def tool_name, do: @tool_name

  @default_skills_dir "~/.osa/skills"
  def default_skills_dir, do: @default_skills_dir
end
