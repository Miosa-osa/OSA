defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — loop started; payload is JSON string with loop_id
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"test_command" => cmd} = input, _opts) do
    %{
      kind: "verify_loop",
      test_command: cmd,
      max_iterations: input["max_iterations"],
      task_id: input["task_id"]
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
      kind: "verify_loop_result",
      loop_id: decoded["loop_id"],
      status: decoded["status"]
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "verify_loop_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
