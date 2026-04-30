defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.Constants do
  @moduledoc "Exported constants for the push_notification tool."

  @tool_name "push_notification"
  def tool_name, do: @tool_name

  @max_title_chars 64
  def max_title_chars, do: @max_title_chars

  @max_body_chars 256
  def max_body_chars, do: @max_body_chars

  # Valid subtitle/urgency levels
  @valid_urgency ~w(low normal critical)
  def valid_urgency, do: @valid_urgency

  @default_urgency "normal"
  def default_urgency, do: @default_urgency

  # Timeout for the shell notification command (ms)
  @command_timeout_ms 5_000
  def command_timeout_ms, do: @command_timeout_ms
end
