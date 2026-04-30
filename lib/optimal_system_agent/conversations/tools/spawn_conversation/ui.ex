defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — summary returned from the conversation
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"topic" => topic} = input, _opts) do
    %{
      kind: "spawn_conversation",
      topic: topic,
      type: input["type"],
      participant_count: length(input["participant_roles"] || [])
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "spawn_conversation_result",
      content: content
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "spawn_conversation_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
