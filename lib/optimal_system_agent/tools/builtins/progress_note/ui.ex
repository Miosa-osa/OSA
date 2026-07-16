defmodule OptimalSystemAgent.Tools.Builtins.ProgressNote.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `SessionSearch.UI` in structure. Each `render/3` call returns a
  structured map consumed by the TUI over the existing PubSub event channel.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — execution succeeded
    * `:rejected`    — user denied
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"note" => note}, _opts) when is_binary(note) do
    %{kind: "progress_note", note: note}
  end

  def render(:tool_result, result_text, _opts) when is_binary(result_text) do
    %{kind: "progress_note_result", message: result_text}
  end

  def render(:rejected, _input, _opts) do
    %{kind: "progress_note_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "progress_note_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
