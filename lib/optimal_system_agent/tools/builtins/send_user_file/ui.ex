defmodule OptimalSystemAgent.Tools.Builtins.SendUserFile.UI do
  @moduledoc "Render maps for the Rust TUI — send_user_file tool."

  def render(:tool_use, %{"path" => path} = input, _opts) do
    %{
      kind: "send_user_file",
      path: path,
      label: Map.get(input, "label", Path.basename(path)),
      description: Map.get(input, "description", "")
    }
  end

  def render(:tool_use, input, _opts) do
    %{kind: "send_user_file", raw: input}
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "send_user_file_result", message: msg}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "send_user_file_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
