defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful recall; payload is the formatted string
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"query" => query} = input, _opts) do
    %{
      kind: "memory_recall",
      query: query,
      category: input["category"],
      limit: input["limit"]
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    count =
      case Regex.run(~r/Found (\d+) memories/, result) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    %{
      kind: "memory_recall_result",
      count: count,
      message: result
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "memory_recall_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "memory_recall_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
