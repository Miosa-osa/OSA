defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful multi-edit; payload is result string or {result, metadata}
    * `:rejected`    — user denied permission
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"edits" => edits} = _input, _opts) when is_list(edits) do
    paths = Enum.map(edits, fn e -> Map.get(e, "path", "") end)

    %{
      kind: "multi_file_edit",
      file_count: length(edits),
      paths: paths
    }
  end

  def render(:tool_use, _input, _opts) do
    %{kind: "multi_file_edit", file_count: 0, paths: []}
  end

  # Plain 2-tuple result (no metadata)
  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "multi_file_edit_result",
      message: result
    }
  end

  # Rich 3-tuple result with per-file metadata (unwrapped by adapter)
  def render(:tool_result, {result, metadata}, _opts)
      when is_binary(result) and is_map(metadata) do
    base = %{
      kind: "multi_file_edit_result",
      message: result
    }

    base
    |> maybe_put(:count, metadata[:count])
    |> maybe_put(:results, metadata[:results])
  end

  def render(:rejected, _input, _opts) do
    %{kind: "multi_file_edit_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "multi_file_edit_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
