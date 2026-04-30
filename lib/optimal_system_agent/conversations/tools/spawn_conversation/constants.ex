defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "spawn_conversation"
  def tool_name, do: @tool_name

  @valid_types ~w(brainstorm design_review red_team user_panel)
  def valid_types, do: @valid_types

  @valid_strategies ~w(round_robin facilitator weighted)
  def valid_strategies, do: @valid_strategies

  @predefined_roles ~w(devils_advocate optimist pragmatist domain_expert)
  def predefined_roles, do: @predefined_roles

  @default_max_turns 20
  def default_max_turns, do: @default_max_turns
end
