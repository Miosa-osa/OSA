defmodule OptimalSystemAgent.Tools.Builtins.Brief.Constants do
  @moduledoc "Exported constants for the brief tool."

  @tool_name "brief"
  def tool_name, do: @tool_name

  # Maximum number of recent memory entries to aggregate into a brief
  @max_recent_entries 20
  def max_recent_entries, do: @max_recent_entries

  # Maximum character length of the generated brief
  @max_brief_chars 2_000
  def max_brief_chars, do: @max_brief_chars

  # Valid time windows for activity scoping (hours)
  @valid_windows [1, 6, 12, 24, 48, 168]
  def valid_windows, do: @valid_windows

  @default_window_hours 24
  def default_window_hours, do: @default_window_hours
end
