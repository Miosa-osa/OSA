defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  The Elixir side of `src/tools/FileEditTool/UI.tsx`. Each `render/3` call
  returns a structured map that the Rust TUI consumes over the existing
  PubSub event channel — the TUI side maps `kind` to a component.

  Stages:
    * `:tool_use`    — model called the tool, before result (show file + diff preview)
    * `:tool_result` — successful edit; payload is the result string + optional metadata
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  # Before execution: show the file path and the replacement being attempted
  def render(:tool_use, %{"path" => path} = input, _opts) do
    %{
      kind: "file_edit",
      path: path,
      old_string: input["old_string"],
      new_string: input["new_string"],
      replace_all: input["replace_all"] == true
    }
  end

  # Successful edit — result is the human-readable summary string
  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "file_edit_result",
      message: result
    }
  end

  # Successful edit with metadata (3-tuple unwrapped by the adapter)
  def render(:tool_result, {result, metadata}, _opts)
      when is_binary(result) and is_map(metadata) do
    base = %{
      kind: "file_edit_result",
      message: result
    }

    base
    |> maybe_put(:diff, metadata[:diff])
    |> maybe_put(:stats, metadata[:stats])
    |> maybe_put(:path, metadata[:path])
  end

  def render(:rejected, _input, _opts) do
    %{kind: "file_edit_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "file_edit_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil

  # ── Private ───────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
