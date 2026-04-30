defmodule OptimalSystemAgent.Tools.Builtins.MemorySave.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful save; payload is the confirmation string
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"content" => content} = input, _opts) do
    %{
      kind: "memory_save",
      content_preview: String.slice(content, 0, 120),
      category: input["category"],
      tags: input["tags"] || []
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "memory_save_result",
      message: result
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "memory_save_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "memory_save_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
