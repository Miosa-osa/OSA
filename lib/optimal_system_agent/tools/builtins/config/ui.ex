defmodule OptimalSystemAgent.Tools.Builtins.Config.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model invoked config; TUI shows the action + key
    * `:tool_result` — result string; TUI displays in output panel
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "config",
      action: action,
      key: input["key"],
      value: input["value"],
      layer: input["layer"]
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "config_result",
      result: result
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "config_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
