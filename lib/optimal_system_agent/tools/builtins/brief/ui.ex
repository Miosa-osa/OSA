defmodule OptimalSystemAgent.Tools.Builtins.Brief.UI do
  @moduledoc "Render maps for the Rust TUI — brief tool."

  def render(:tool_use, %{"window_hours" => h} = input, _opts) do
    %{kind: "brief", window_hours: h, topic: Map.get(input, "topic")}
  end

  def render(:tool_use, input, _opts) do
    %{kind: "brief", window_hours: nil, topic: Map.get(input, "topic")}
  end

  def render(:tool_result, text, _opts) when is_binary(text) do
    %{kind: "brief_result", text: text}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "brief_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
