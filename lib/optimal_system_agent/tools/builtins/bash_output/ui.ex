defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.UI do
  @moduledoc """
  Render maps for the Rust TUI. Mirrors `TaskOutput.UI`.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — execution succeeded
    * `:rejected`    — permission denied
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"background_id" => id} = input, _opts) do
    %{
      kind: "bash_output",
      background_id: id,
      kill: input["kill"] == true or input["kill"] == "true"
    }
  end

  def render(:tool_result, result_text, _opts) when is_binary(result_text) do
    %{kind: "bash_output_result", message: result_text}
  end

  def render(:rejected, _input, _opts) do
    %{kind: "bash_output_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "bash_output_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
