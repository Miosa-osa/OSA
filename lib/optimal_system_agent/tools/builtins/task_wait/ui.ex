defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `TaskResume.UI` in structure. Each `render/3` call returns a
  structured map consumed by the TUI over the existing PubSub event channel.

  Stages:
    * `:tool_use`    — model called the tool, before result (shows what it's
      blocking on, so the TUI can render a "waiting on N agents" indicator)
    * `:tool_result` — the wait finished (satisfied or timed out)
    * `:rejected`    — user denied (reserved for Phase 4 ask flow)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"agent_ids" => agent_ids} = input, _opts) do
    %{
      kind: "task_wait",
      agent_ids: agent_ids,
      require_all: Map.get(input, "require_all", true) != false
    }
  end

  def render(:tool_result, result_text, _opts) when is_binary(result_text) do
    %{
      kind: "task_wait_result",
      message: result_text
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "task_wait_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "task_wait_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
