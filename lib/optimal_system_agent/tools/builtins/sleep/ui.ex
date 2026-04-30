defmodule OptimalSystemAgent.Tools.Builtins.Sleep.UI do
  @moduledoc "Render maps for the Rust TUI."

  def render(:tool_use, %{"seconds" => s}, _opts) do
    %{kind: "sleep", seconds: s}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "sleep_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "sleep_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
