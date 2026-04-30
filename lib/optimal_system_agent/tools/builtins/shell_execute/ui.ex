defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors `FileRead.UI`. Each `render/3` call returns a structured map
  consumed by the TUI over the existing PubSub event channel.

  Stages:
    * `:tool_use`    — model called the tool, before execution
    * `:tool_result` — successful execution result
    * `:rejected`    — permission denied
    * `:error`       — execution error
    * `:progress`    — (currently unused for shell_execute)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"command" => command} = input, _opts) do
    %{
      kind: "shell_execute",
      command: command,
      cwd: input["cwd"]
    }
  end

  def render(:tool_result, output, _opts) when is_binary(output) do
    %{
      kind: "shell_execute_result",
      bytes: byte_size(output),
      truncated: String.contains?(output, "[output truncated at 100KB]")
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "shell_execute_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "shell_execute_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
