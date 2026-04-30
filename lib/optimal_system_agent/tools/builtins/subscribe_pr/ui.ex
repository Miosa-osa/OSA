defmodule OptimalSystemAgent.Tools.Builtins.SubscribePr.UI do
  @moduledoc "Render maps for the Rust TUI — subscribe_pr tool."

  def render(:tool_use, %{"pr_url" => url} = input, _opts) do
    %{
      kind: "subscribe_pr",
      pr_url: url,
      events: Map.get(input, "events", ["merged", "closed"]),
      poll_interval_minutes: Map.get(input, "poll_interval_minutes", 5)
    }
  end

  def render(:tool_use, input, _opts) do
    %{kind: "subscribe_pr", raw: input}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "subscribe_pr_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "subscribe_pr_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
