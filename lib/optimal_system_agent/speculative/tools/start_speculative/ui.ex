defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — speculative execution started; payload is JSON with speculative_id
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"predicted_next_task" => task} = input, _opts) do
    %{
      kind: "start_speculative",
      predicted_next_task: task,
      assumption_count: length(input["assumptions"] || []),
      agent_id: input["agent_id"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    decoded =
      Jason.decode(content)
      |> then(fn
        {:ok, m} -> m
        _ -> %{}
      end)

    %{
      kind: "start_speculative_result",
      speculative_id: decoded["speculative_id"],
      status: decoded["status"]
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "start_speculative_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
