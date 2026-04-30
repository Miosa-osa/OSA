defmodule OptimalSystemAgent.Tools.Builtins.TeamCreate.Constants do
  @moduledoc "Exported constants for the team_create tool."

  @tool_name "team_create"
  def tool_name, do: @tool_name

  @max_name_length 120
  def max_name_length, do: @max_name_length

  @max_members 32
  def max_members, do: @max_members
end
