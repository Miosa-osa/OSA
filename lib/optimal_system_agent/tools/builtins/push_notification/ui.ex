defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.UI do
  @moduledoc "Render maps for the Rust TUI — push_notification tool."

  def render(:tool_use, %{"title" => title, "body" => body} = input, _opts) do
    %{
      kind: "push_notification",
      title: title,
      body: body,
      urgency: Map.get(input, "urgency", "normal")
    }
  end

  def render(:tool_use, input, _opts) do
    %{kind: "push_notification", raw: input}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "push_notification_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "push_notification_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
