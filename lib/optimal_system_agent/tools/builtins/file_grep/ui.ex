defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Follows the pattern of `FileRead.UI`. Each `render/3` call returns a
  structured map the Rust TUI consumes over the PubSub event channel —
  the TUI side maps `kind` to a component.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful search result
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
    * `:progress`    — unused for file_grep (grep is fast)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) do
    %{
      kind: "file_grep",
      pattern: input["pattern"],
      path: input["path"],
      glob: input["glob"],
      output_mode: input["output_mode"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    line_count = content |> String.split("\n") |> length()

    %{
      kind: "file_grep_result",
      lines: line_count,
      bytes: byte_size(content)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "file_grep_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "file_grep_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
