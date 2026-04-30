defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `FileRead.UI` in structure. Each `render/3` call returns a
  structured map consumed by the TUI over the existing PubSub event channel.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — execution succeeded
    * `:rejected`    — user denied (reserved for Phase 4 ask flow)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"agent_id" => agent_id}, _opts) do
    %{
      kind: "task_output",
      agent_id: agent_id
    }
  end

  def render(:tool_result, result_text, _opts) when is_binary(result_text) do
    %{
      kind: "task_output_result",
      message: result_text
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "task_output_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "task_output_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
