defmodule OptimalSystemAgent.Tools.Builtins.RemoteTrigger.UI do
  @moduledoc "Render maps for the Rust TUI."

  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "remote_trigger",
      action: action,
      trigger_id: input["trigger_id"],
      type: input["type"]
    }
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "remote_trigger_result", message: msg}
  end

  def render(:rejected, _input, _opts), do: %{kind: "remote_trigger_rejected"}

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "remote_trigger_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
