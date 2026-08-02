defmodule OptimalSystemAgent.Tools.Builtins.LatexCompile.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `ShellExecute.UI`. Each `render/3` call returns a structured map
  consumed by the TUI over the existing PubSub event channel.

  Stages:
    * `:tool_use`    — model called the tool, before execution
    * `:tool_result` — execution result (success or a structured compile error)
    * `:rejected`    — permission denied
    * `:error`       — execution error (string message)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) when is_map(input) do
    %{
      kind: "latex_compile",
      engine: input["engine"] || "tectonic",
      jobname: input["jobname"],
      tex_path: input["tex_path"],
      inline: is_binary(input["tex_content"])
    }
  end

  def render(:tool_result, %{status: status} = result, _opts) do
    %{
      kind: "latex_compile_result",
      status: status,
      engine: result[:engine],
      pdf_path: result[:pdf_path],
      log_path: result[:log_path],
      output_dir: result[:output_dir],
      error_count: length(result[:errors] || [])
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "latex_compile_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "latex_compile_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
