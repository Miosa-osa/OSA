defmodule OptimalSystemAgent.Tools.Builtins.StructuralEdit.UI do
  @moduledoc """
  Render maps for the Rust TUI. Mirrors `MultiFileEdit.UI`.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful structural edit; payload is result string or
                       {result, metadata}
    * `:rejected`    — user denied permission
    * `:error`       — execution error (includes the per-target report)
  """

  alias OptimalSystemAgent.Tools.Builtins.StructuralEdit.Handler

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) when is_map(input) do
    paths = Handler.all_target_paths(input)
    %{kind: "structural_edit", file_count: length(paths), paths: paths}
  end

  def render(:tool_use, _input, _opts) do
    %{kind: "structural_edit", file_count: 0, paths: []}
  end

  # Plain 2-tuple result (no metadata)
  def render(:tool_result, result, _opts) when is_binary(result) do
    %{kind: "structural_edit_result", message: result}
  end

  # Rich 3-tuple result with per-file metadata (unwrapped by adapter)
  def render(:tool_result, {result, metadata}, _opts)
      when is_binary(result) and is_map(metadata) do
    %{kind: "structural_edit_result", message: result}
    |> maybe_put(:count, metadata[:count])
    |> maybe_put(:results, metadata[:results])
  end

  def render(:rejected, _input, _opts) do
    %{kind: "structural_edit_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "structural_edit_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
