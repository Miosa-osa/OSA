defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Each `render/3` call returns a structured map that the Rust TUI consumes
  over the existing PubSub event channel — the TUI side maps `kind` to a
  component.

  Stages:
    * `:tool_use`    — model called the tool, before result (show action + path)
    * `:tool_result` — successful operation; payload is result string or
                       `{result, metadata}` for the 3-tuple `read` return
    * `:rejected`    — user denied permission (Phase 4 ask flow)
    * `:error`       — execution error
    * `:progress`    — reserved; currently unused for notebook_edit
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"action" => action, "path" => path} = input, _opts) do
    %{
      kind: "notebook_edit",
      action: action,
      path: path,
      index: input["index"],
      cell_type: input["cell_type"],
      position: input["position"]
    }
  end

  # read result — carries structured cell_count + path metadata
  def render(:tool_result, {result, %{cell_count: n, path: path}}, _opts)
      when is_binary(result) do
    %{
      kind: "notebook_edit_result",
      action: "read",
      message: result,
      cell_count: n,
      path: path
    }
  end

  # mutating action result — plain string summary
  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "notebook_edit_result",
      message: result
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "notebook_edit_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "notebook_edit_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
