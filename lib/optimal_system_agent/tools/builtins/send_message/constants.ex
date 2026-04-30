defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Constants do
  @moduledoc """
  Exported constants for `send_message`.

 Other modules reference
  `tool_name/0` so a rename propagates automatically.
  """

  @tool_name "send_message"
  def tool_name, do: @tool_name

  @pending_table :osa_agent_messages
  def pending_table, do: @pending_table
end
