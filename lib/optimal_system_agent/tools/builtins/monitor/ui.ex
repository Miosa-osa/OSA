defmodule OptimalSystemAgent.Tools.Builtins.Monitor.UI do
  @moduledoc "Render maps for the Rust TUI."

  def render(:tool_use, %{"kind" => kind, "target" => target} = input, _opts) do
    %{
      kind: "monitor",
      watch_kind: kind,
      target: target,
      duration_seconds: input["duration_seconds"],
      poll_interval_ms: input["poll_interval_ms"]
    }
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "monitor_result", message: msg}
  end

  def render(:rejected, _input, _opts), do: %{kind: "monitor_rejected"}

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "monitor_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
