defmodule Canopy.EventBus do
  @moduledoc "Internal event bus using Phoenix.PubSub."

  @pubsub Canopy.PubSub

  def broadcast(topic, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic, event)
  end

  def broadcast!(topic, event) do
    Phoenix.PubSub.broadcast!(@pubsub, topic, event)
  end

  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  # Convenience topic builders
  def workspace_topic(workspace_id), do: "workspace:#{workspace_id}"
  def agent_topic(agent_id), do: "agent:#{agent_id}"
  def session_topic(session_id), do: "session:#{session_id}"
  def activity_topic, do: "activity:global"
  def logs_topic, do: "logs:global"
end
