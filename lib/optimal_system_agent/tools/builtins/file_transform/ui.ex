defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.UI do
  @moduledoc """
  Render maps for the Rust TUI. Same contract as `FileWrite.UI`.

  The TUI shows the path and the operation count. It deliberately does not get a
  diff: `file_transform` never computes one, because computing it would mean
  holding both versions to render text the model must not be sent. The operator
  sees the file change in their editor and in `git diff`; the saving is the
  point of the tool.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"path" => path} = input, _opts) do
    ops = Map.get(input, "operations", [])

    %{
      kind: "file_transform",
      path: path,
      operations: if(is_list(ops), do: length(ops), else: 0),
      dry_run: Map.get(input, "dry_run") == true
    }
  end

  def render(:tool_result, {result, %{path: path, operations: n}}, _opts)
      when is_binary(result) do
    %{kind: "file_transform_result", path: path, operations: n}
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    %{kind: "file_transform_result", operations: 0}
  end

  def render(:rejected, _input, _opts), do: %{kind: "file_transform_rejected"}

  def render(:error, msg, _opts) when is_binary(msg),
    do: %{kind: "file_transform_error", message: msg}

  def render(_stage, _payload, _opts), do: nil
end
