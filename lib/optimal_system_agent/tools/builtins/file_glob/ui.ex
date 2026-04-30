defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful glob; payload is the result string
    * `:rejected`    — user denied permission
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"pattern" => pattern} = input, _opts) do
    %{
      kind: "file_glob",
      pattern: pattern,
      path: input["path"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    line_count = content |> String.split("\n") |> length()

    %{
      kind: "file_glob_result",
      lines: line_count,
      bytes: byte_size(content)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "file_glob_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "file_glob_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
