defmodule OptimalSystemAgent.Tools.Builtins.ListSkills.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "list_skills"
  def tool_name, do: @tool_name

  @default_skills_dir "~/.osa/skills"
  def default_skills_dir, do: @default_skills_dir
end
