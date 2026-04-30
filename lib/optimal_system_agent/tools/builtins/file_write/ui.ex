defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Each `render/3` call returns a structured map that the Rust TUI consumes
  over the existing PubSub event channel. The TUI side maps `kind` to a
  component.

  Stages:
    * `:tool_use`    — model called the tool, before execution
    * `:tool_result` — successful write; payload is the result string (with optional metadata)
    * `:rejected`    — permission denied
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"path" => path} = _input, _opts) do
    %{
      kind: "file_write",
      path: path
    }
  end

  def render(:tool_result, {result, %{diff: _diff, stats: stats, path: path}}, _opts)
      when is_binary(result) do
    %{
      kind: "file_write_result",
      path: path,
      additions: Map.get(stats, :additions, 0),
      deletions: Map.get(stats, :deletions, 0)
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    # Extract line count from the result string "path\nN lines written\n..."
    line_count =
      case Regex.run(~r/(\d+) lines written/, result) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    %{
      kind: "file_write_result",
      lines: line_count
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "file_write_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "file_write_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
