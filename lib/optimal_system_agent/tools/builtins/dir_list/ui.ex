defmodule OptimalSystemAgent.Tools.Builtins.DirList.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Each `render/3` call returns a structured map consumed by the TUI over the
  existing PubSub event channel. The TUI maps `kind` to a component.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful listing; payload is the result string
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
    * `:progress`    — reserved; currently unused for dir_list
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    %{
      kind: "dir_list",
      path: Map.get(input, "path", ".")
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    entry_count =
      content
      |> String.split("\n", trim: true)
      |> length()

    %{
      kind: "dir_list_result",
      entries: entry_count
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "dir_list_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "dir_list_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
