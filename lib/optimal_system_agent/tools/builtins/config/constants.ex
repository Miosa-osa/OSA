defmodule OptimalSystemAgent.Tools.Builtins.Config.Constants do
  @moduledoc """
  Exported constants for `config`.


  """

  @tool_name "config"
  def tool_name, do: @tool_name

  @read_actions ~w(get list)
  def read_actions, do: @read_actions

  @write_actions ~w(set)
  def write_actions, do: @write_actions
end
