defmodule OptimalSystemAgent.Tools.Builtins.FileRead.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  The Elixir side of `src/tools/FileReadTool/UI.tsx`. Each `render/3` call
  returns a structured map that the Rust TUI consumes over the existing
  PubSub event channel — the TUI side maps `kind` to a component.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful read; payload is content or `{:image, _}`
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
    * `:progress`    — long-running progress (currently unused for file_read)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"path" => path} = input, _opts) do
    %{
      kind: "file_read",
      path: path,
      offset: input["offset"],
      limit: input["limit"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    line_count = content |> String.split("\n") |> length()

    %{
      kind: "file_read_result",
      lines: line_count,
      bytes: byte_size(content)
    }
  end

  def render(:tool_result, {:image, %{path: path, media_type: media_type}}, _opts) do
    %{
      kind: "file_read_image",
      path: path,
      media_type: media_type
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "file_read_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "file_read_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
