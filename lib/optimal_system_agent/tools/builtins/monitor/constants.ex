defmodule OptimalSystemAgent.Tools.Builtins.Monitor.Constants do
  @moduledoc "Exported constants for the monitor tool."

  @tool_name "monitor"
  def tool_name, do: @tool_name

  @max_duration_seconds 600
  def max_duration_seconds, do: @max_duration_seconds

  @default_poll_interval_ms 1_000
  def default_poll_interval_ms, do: @default_poll_interval_ms

  @kinds ~w(file process url command)
  def kinds, do: @kinds

  @modes ~w(once repeat)
  def modes, do: @modes
end
